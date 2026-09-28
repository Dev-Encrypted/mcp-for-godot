"""Reparo restrito de UID em um único arquivo de cena fechado.

Não carrega recursos, não varre o projeto e não considera referências dinâmicas.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid
from .file_transaction import _ProjectLock


MAX_BYTES = 524_288
MAX_MATCHES = 64
TTL_SECONDS = 300
HEX_SHA = re.compile(r"[0-9a-f]{64}\Z")
UID = re.compile(r"uid://[a-z0-9]+\Z")
HEADER = re.compile(r'^\[gd_(?:scene|resource)\b[^\n]*\buid="(uid://[a-z0-9]+)"')
EXTERNAL = re.compile(r'^\[ext_resource\b[^\n]*\buid="([^"]+)"[^\n]*\bpath="([^"]+)"[^\n]*\]')


class ResourceTransactionError(Exception):
    def __init__(self, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ResourceTransactions:
    def __init__(self, project: Path, owner: str):
        self.project = project.resolve(strict=True)
        self.owner = owner
        self.previews: dict[str, dict] = {}
        self.checkpoints: dict[str, Path] = {}

    def _path(self, raw: str, extensions: set[str]) -> tuple[str, Path]:
        if not isinstance(raw, str) or not raw.startswith("res://") or "\\" in raw or "\x00" in raw:
            raise ResourceTransactionError("invalid_path", "Use um caminho res:// local.")
        relative = raw[6:]
        parts = relative.split("/")
        if not parts or any(not part or part in {".", ".."} or part.startswith(".") or ":" in part for part in parts):
            raise ResourceTransactionError("invalid_path", "Caminho oculto, absoluto ou traversal recusado.")
        if Path(relative).suffix.lower() not in extensions:
            raise ResourceTransactionError("unsupported_type", "Tipo de arquivo não aceito pelo reparo de UID.")
        path = self.project
        for part in parts:
            path /= part
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise ResourceTransactionError("invalid_path", "Link ou junction recusado.")
        path = path.resolve(strict=False)
        if not path.is_relative_to(self.project) or not path.is_file():
            raise ResourceTransactionError("invalid_path", "Arquivo fora do projeto ou inexistente.")
        return "res://" + Path(relative).as_posix(), path

    def _new_path(self, raw: str, extension: str) -> tuple[str, Path]:
        if not isinstance(raw, str) or not raw.startswith("res://") or "\\" in raw or "\x00" in raw:
            raise ResourceTransactionError("invalid_path", "Use caminho res:// local.")
        relative = raw[6:]
        parts = relative.split("/")
        if not parts or any(not part or part in {".", ".."} or part.startswith(".") or ":" in part for part in parts) or Path(relative).suffix.lower() != extension:
            raise ResourceTransactionError("invalid_path", "Destino inválido.")
        path = self.project
        for part in parts:
            path /= part
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise ResourceTransactionError("invalid_path", "Link ou junction recusado.")
        path = path.resolve(strict=False)
        if not path.is_relative_to(self.project) or not path.parent.is_dir() or path.exists():
            raise ResourceTransactionError("output_conflict", "Destino já existe ou pasta indisponível.")
        return "res://" + Path(relative).as_posix(), path

    def _stage(self, stage_id: str) -> Path:
        if not isinstance(stage_id, str) or re.fullmatch(r"[0-9a-f]{32}", stage_id) is None:
            raise ResourceTransactionError("invalid_stage", "Identificador de estágio inválido.")
        path = self.project
        for part in (".godot", "ai_mcp", "resource-staging", stage_id + ".tres"):
            path /= part
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise ResourceTransactionError("invalid_stage", "Estágio usa link ou junction.")
        if not path.resolve().is_relative_to(self.project) or not path.is_file():
            raise ResourceTransactionError("invalid_stage", "Candidato não existe no projeto.")
        return path

    def prepare_mesh_stage(self) -> dict:
        path = self.project
        for part in (".godot", "ai_mcp", "resource-staging"):
            path /= part
            if path.exists() and (path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project)):
                raise ResourceTransactionError("invalid_stage", "Diretório de estágio usa link ou sai do projeto.")
        path.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project):
            raise ResourceTransactionError("invalid_stage", "Diretório de estágio inseguro.")
        return {"ready": True, "staging_path": "res://.godot/ai_mcp/resource-staging"}

    def _references(self, output_name: str, uid: str | None) -> list[str]:
        hits: list[str] = []
        seen = 0
        for base, directories, files in os.walk(self.project, followlinks=False):
            folder = Path(base)
            kept = []
            for name in directories:
                child = folder / name
                if name in {".godot", ".git"}:
                    continue
                if child.is_symlink() or getattr(child, "is_junction", lambda: False)() or not child.resolve().is_relative_to(self.project):
                    raise ResourceTransactionError("reference_scan_incomplete", "Diretório vinculado impede prova de ausência de consumidor.")
                kept.append(name)
            directories[:] = kept
            for name in files:
                candidate = folder / name
                if candidate.suffix.lower() not in {".tscn", ".tres", ".gd", ".gdshader", ".godot"}:
                    continue
                if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)() or not candidate.resolve().is_relative_to(self.project):
                    raise ResourceTransactionError("reference_scan_incomplete", "Arquivo vinculado impede prova de ausência de consumidor.")
                if "res://" + candidate.relative_to(self.project).as_posix() == output_name:
                    continue
                seen += 1
                if seen > 500 or candidate.stat().st_size > MAX_BYTES:
                    raise ResourceTransactionError("reference_scan_incomplete", "Varredura de consumidores excedeu limites.")
                contents = candidate.read_bytes()
                if output_name.encode() in contents or (uid and uid.encode() in contents):
                    hits.append("res://" + candidate.relative_to(self.project).as_posix())
                    if len(hits) >= 16:
                        return hits
        return hits

    def _read(self, path: Path) -> bytes:
        if path.stat().st_size > MAX_BYTES:
            raise ResourceTransactionError("file_too_large", "Arquivo acima de 512 KiB.")
        return path.read_bytes()

    def _state(self, scene: str, state: dict) -> None:
        if not isinstance(state, dict) or not isinstance(state.get("project_path"), str) or Path(state["project_path"]).resolve() != self.project:
            raise ResourceTransactionError("editor_unavailable", "Editor do projeto não confirmado.")
        opened = state.get("open_scenes")
        unsaved = state.get("unsaved_scenes")
        if not isinstance(opened, list) or not isinstance(unsaved, list):
            raise ResourceTransactionError("editor_state_unknown", "Editor não informou cenas abertas e não salvas.")
        if scene in opened or scene in unsaved or state.get("active_scene_path") == scene:
            raise ResourceTransactionError("scene_open", "Feche a cena antes de reparar seu UID no disco.")
        if unsaved or state.get("playing"):
            raise ResourceTransactionError("editor_busy", "Salve cenas pendentes e pare o Play.")

    def _work_dir(self) -> Path:
        path = self.project
        for part in (".godot", "ai_mcp", "transactions"):
            path /= part
            if path.exists() and (path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project)):
                raise ResourceTransactionError("invalid_checkpoint", "Diretório de checkpoint inseguro.")
        path.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project):
            raise ResourceTransactionError("invalid_checkpoint", "Checkpoint fora do projeto.")
        return path

    def _lock(self, base: Path) -> _ProjectLock:
        return _ProjectLock(base / "project.lock", ResourceTransactionError, self.owner)

    def _manifest_write(self, folder: Path, manifest: dict) -> None:
        temp = folder / ("manifest." + uuid.uuid4().hex + ".tmp")
        try:
            with temp.open("xb") as stream:
                stream.write(json.dumps(manifest, sort_keys=True).encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, folder / "manifest.json")
        finally:
            temp.unlink(missing_ok=True)

    def _checkpoint(self, checkpoint_id: str, kind: str) -> tuple[Path, dict]:
        if not isinstance(checkpoint_id, str) or re.fullmatch(r"[0-9a-f]{32}", checkpoint_id) is None:
            raise ResourceTransactionError("invalid_checkpoint", "Identificador de checkpoint inválido.")
        folder = self._work_dir() / checkpoint_id
        path = folder / "manifest.json"
        if not folder.is_dir() or folder.is_symlink() or getattr(folder, "is_junction", lambda: False)() or not path.is_file() or path.is_symlink() or getattr(path, "is_junction", lambda: False)():
            raise ResourceTransactionError("invalid_checkpoint", "Checkpoint indisponível ou vinculado.")
        try:
            if path.stat().st_size > 4096:
                raise ResourceTransactionError("checkpoint_corrupt", "Manifesto excede limite.")
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ResourceTransactionError("checkpoint_corrupt", "Manifesto ilegível.") from exc
        uid_keys = {"owner", "scene", "resource", "source_sha256", "before_sha256", "after_sha256", "state"}
        mesh_keys = {"owner", "kind", "scene", "scene_sha256", "output", "after_sha256", "state"}
        expected_keys = uid_keys if kind == "uid" else mesh_keys
        if (not isinstance(manifest, dict) or set(manifest) != expected_keys or not isinstance(manifest["owner"], str)
                or len(manifest["owner"]) > 128 or manifest["state"] not in {"prepared", "applied", "restored"}
                or not isinstance(manifest["after_sha256"], str) or not HEX_SHA.fullmatch(manifest["after_sha256"])):
            raise ResourceTransactionError("checkpoint_corrupt", "Manifesto inválido.")
        if kind == "uid":
            if (not isinstance(manifest["before_sha256"], str) or not HEX_SHA.fullmatch(manifest["before_sha256"])
                    or not isinstance(manifest["source_sha256"], str) or not HEX_SHA.fullmatch(manifest["source_sha256"])):
                raise ResourceTransactionError("checkpoint_corrupt", "Hashes de UID inválidos.")
            scene_name, _ = self._path(manifest["scene"], {".tscn"})
            resource_name, _ = self._path(manifest["resource"], {".tscn", ".tres"})
            if scene_name == resource_name:
                raise ResourceTransactionError("checkpoint_corrupt", "Cena e recurso iguais.")
            backup = folder / "before.tscn"
            if not backup.is_file() or backup.is_symlink() or getattr(backup, "is_junction", lambda: False)() or _sha(self._read(backup)) != manifest["before_sha256"]:
                raise ResourceTransactionError("checkpoint_corrupt", "Cópia anterior divergente.")
        else:
            if manifest["kind"] != "mesh_library" or not isinstance(manifest["scene_sha256"], str) or not HEX_SHA.fullmatch(manifest["scene_sha256"]):
                raise ResourceTransactionError("checkpoint_corrupt", "Manifesto MeshLibrary inválido.")
            self._path(manifest["scene"], {".tscn"})
            self._validate_new_name(manifest["output"], ".tres")
        return folder, manifest

    def _validate_new_name(self, raw: str, extension: str) -> Path:
        if not isinstance(raw, str) or not raw.startswith("res://") or "\\" in raw or "\x00" in raw:
            raise ResourceTransactionError("invalid_checkpoint", "Destino inválido.")
        relative = raw[6:]
        parts = relative.split("/")
        if (not parts or any(not part or part in {".", ".."} or part.startswith(".") or ":" in part for part in parts)
                or Path(relative).suffix.lower() != extension):
            raise ResourceTransactionError("invalid_checkpoint", "Destino inválido.")
        path = self.project
        for part in parts:
            path /= part
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise ResourceTransactionError("invalid_checkpoint", "Destino vinculado.")
        if not path.resolve(strict=False).is_relative_to(self.project):
            raise ResourceTransactionError("invalid_checkpoint", "Destino fora do projeto.")
        return path

    def list_checkpoints(self, limit: int = 64) -> list[dict]:
        if type(limit) is not int or not 1 <= limit <= 128:
            raise ResourceTransactionError("invalid_query", "limit deve estar entre 1 e 128.")
        base = self._work_dir()
        ids = [entry.name for entry in base.iterdir() if re.fullmatch(r"[0-9a-f]{32}", entry.name)]
        if len(ids) > 1024:
            raise ResourceTransactionError("checkpoint_limit", "Muitos checkpoints.")
        result = []
        for checkpoint_id in sorted(ids, reverse=True):
            folder = base / checkpoint_id
            if not folder.is_dir() or folder.is_symlink() or getattr(folder, "is_junction", lambda: False)():
                raise ResourceTransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} vinculado ou inválido.")
            path = folder / "manifest.json"
            if not path.is_file() or path.is_symlink() or getattr(path, "is_junction", lambda: False)() or path.stat().st_size > 4096:
                raise ResourceTransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} inválido.")
            try:
                peek = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise ResourceTransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} inválido.") from exc
            if not isinstance(peek, dict):
                raise ResourceTransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} inválido.")
            if "scene" not in peek and "path" in peek:
                continue
            if "scene" not in peek:
                raise ResourceTransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} sem tipo conhecido.")
            kind = "mesh_library" if peek.get("kind") == "mesh_library" else "uid"
            _, manifest = self._checkpoint(checkpoint_id, kind)
            target = self._path(manifest["scene"], {".tscn"})[1] if kind == "uid" else self._validate_new_name(manifest["output"], ".tres")
            actual = _sha(self._read(target)) if target.is_file() else None
            before = manifest["before_sha256"] if kind == "uid" else None
            status = "recoverable" if actual == manifest["after_sha256"] else "already_restored" if actual == before else "conflict"
            if kind == "uid":
                dependency = self._path(manifest["resource"], {".tscn", ".tres"})[1]
                if _sha(self._read(dependency)) != manifest["source_sha256"]:
                    status = "conflict"
            elif _sha(self._read(self._path(manifest["scene"], {".tscn"})[1])) != manifest["scene_sha256"]:
                status = "conflict"
            result.append({"checkpoint_id": checkpoint_id, "kind": kind, "path": manifest["scene"] if kind == "uid" else manifest["output"], "state": manifest["state"], "before_sha256": before, "after_sha256": manifest["after_sha256"], "actual_sha256": actual, "recovery": status})
            if len(result) >= limit:
                break
        return result

    def _candidate(self, scene: Path, resource: Path, resource_name: str) -> tuple[bytes, bytes, list[dict], str]:
        before = self._read(scene)
        source = self._read(resource)
        try:
            text = before.decode("utf-8")
            source_text = source.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ResourceTransactionError("invalid_encoding", "Cena e recurso devem ser UTF-8.") from exc
        header = HEADER.match(source_text)
        if header is None:
            raise ResourceTransactionError("uid_source_unverified", "Recurso não declara UID em cabeçalho .tscn/.tres.")
        correct_uid = header.group(1)
        if not UID.fullmatch(correct_uid):
            raise ResourceTransactionError("uid_source_unverified", "UID de origem inválido.")
        lines = text.splitlines(keepends=True)
        matches: list[dict] = []
        for index, line in enumerate(lines):
            parsed = EXTERNAL.match(line.rstrip("\r\n"))
            if parsed is None and line.startswith("[ext_resource") and f'path="{resource_name}"' in line:
                raise ResourceTransactionError("invalid_reference", "Ordem ou sintaxe da referência não suportada.")
            if parsed is None or parsed.group(2) != resource_name:
                continue
            old_uid = parsed.group(1)
            if old_uid == correct_uid:
                continue
            if not UID.fullmatch(old_uid):
                raise ResourceTransactionError("invalid_reference", "Referência UID malformada.")
            needle = f'uid="{old_uid}"'
            if line.count(needle) != 1:
                raise ResourceTransactionError("invalid_reference", "UID ambíguo na linha.")
            lines[index] = line.replace(needle, f'uid="{correct_uid}"', 1)
            matches.append({"line": index + 1, "old_uid": old_uid, "new_uid": correct_uid})
            if len(matches) > MAX_MATCHES:
                raise ResourceTransactionError("too_many_references", "Mais de 64 referências na cena.")
        if not matches:
            raise ResourceTransactionError("no_repair_needed", "Cena não contém UID divergente desse recurso.")
        after = "".join(lines).encode("utf-8")
        if len(after) > MAX_BYTES:
            raise ResourceTransactionError("file_too_large", "Cena após reparo acima de 512 KiB.")
        return before, after, matches, _sha(source)

    def preview_uid(self, scene_raw: str, resource_raw: str, expected_scene_sha256: str, expected_resource_sha256: str, state: dict) -> dict:
        scene_name, scene = self._path(scene_raw, {".tscn"})
        resource_name, resource = self._path(resource_raw, {".tscn", ".tres"})
        if scene == resource or not all(isinstance(value, str) and HEX_SHA.fullmatch(value) for value in (expected_scene_sha256, expected_resource_sha256)):
            raise ResourceTransactionError("invalid_target", "Caminhos ou hashes inválidos.")
        self._state(scene_name, state)
        before, after, matches, resource_hash = self._candidate(scene, resource, resource_name)
        if _sha(before) != expected_scene_sha256 or resource_hash != expected_resource_sha256:
            raise ResourceTransactionError("hash_conflict", "Cena ou recurso mudou.")
        now = time.monotonic()
        self.previews = {key: value for key, value in self.previews.items() if now - value["created"] <= TTL_SECONDS}
        if len(self.previews) >= 16:
            raise ResourceTransactionError("preview_limit", "Limite de prévias pendentes.")
        preview_id = uuid.uuid4().hex
        self.previews[preview_id] = {"scene": scene_name, "resource": resource_name, "before": expected_scene_sha256, "source": resource_hash, "after": after, "after_sha256": _sha(after), "created": now}
        diff = "".join(difflib.unified_diff(before.decode("utf-8").splitlines(True), after.decode("utf-8").splitlines(True), fromfile=scene_name + ":before", tofile=scene_name + ":after"))
        return {"preview_id": preview_id, "scene_path": scene_name, "resource_path": resource_name, "before_sha256": expected_scene_sha256, "resource_sha256": resource_hash, "after_sha256": _sha(after), "matches": matches, "diff": diff[:32768], "diff_truncated": len(diff) > 32768, "consumer_scope": "one_explicit_scene", "dynamic_consumers": "unknown", "load_performed": False}

    def apply_uid(self, preview_id: str, state_getter) -> dict:
        if not isinstance(preview_id, str) or re.fullmatch(r"[0-9a-f]{32}", preview_id) is None:
            raise ResourceTransactionError("invalid_preview", "Identificador de prévia inválido.")
        item = self.previews.get(preview_id)
        if item is None or time.monotonic() - item["created"] > TTL_SECONDS:
            raise ResourceTransactionError("invalid_preview", "Prévia não existe nesta sessão.")
        scene_name, scene = self._path(item["scene"], {".tscn"})
        _, resource = self._path(item["resource"], {".tscn", ".tres"})
        self._state(scene_name, state_getter())
        base = self._work_dir()
        lock = self._lock(base)
        try:
            self._state(scene_name, state_getter())
            if _sha(self._read(scene)) != item["before"] or _sha(self._read(resource)) != item["source"]:
                raise ResourceTransactionError("hash_conflict", "Cena ou recurso mudou desde a prévia.")
            checkpoint_id = uuid.uuid4().hex
            folder = base / checkpoint_id
            folder.mkdir()
            before = self._read(scene)
            with (folder / "before.tscn").open("xb") as stream:
                stream.write(before)
                stream.flush()
                os.fsync(stream.fileno())
            manifest = {"owner": self.owner, "scene": scene_name, "resource": item["resource"], "source_sha256": item["source"], "before_sha256": item["before"], "after_sha256": item["after_sha256"], "state": "prepared"}
            self._manifest_write(folder, manifest)
            self.checkpoints[checkpoint_id] = folder
            temp = scene.with_name(scene.name + ".ai_mcp_" + checkpoint_id + ".tmp")
            try:
                with temp.open("xb") as stream:
                    stream.write(item["after"])
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp, scene)
            finally:
                temp.unlink(missing_ok=True)
            try:
                if _sha(self._read(scene)) != item["after_sha256"]:
                    raise ResourceTransactionError("postcondition_failed", "Arquivo após troca não confere.")
                manifest["state"] = "applied"
                self._manifest_write(folder, manifest)
            except (OSError, ResourceTransactionError) as exc:
                raise ResourceTransactionError("postcondition_failed", "Reparo aplicado, mas verificação ou manifesto final falhou; checkpoint preservado.", {"checkpoint_id": checkpoint_id}) from exc
        finally:
            lock.unlink(missing_ok=True)
        self.previews.pop(preview_id, None)
        return {"checkpoint_id": checkpoint_id, "scene_path": scene_name, "before_sha256": item["before"], "after_sha256": item["after_sha256"], "rollback": "hash_guarded"}

    def rollback_uid(self, checkpoint_id: str, expected_current_sha256: str, state_getter) -> dict:
        if not isinstance(expected_current_sha256, str) or not HEX_SHA.fullmatch(expected_current_sha256):
            raise ResourceTransactionError("invalid_hash", "SHA-256 atual inválido.")
        folder, manifest = self._checkpoint(checkpoint_id, "uid")
        if manifest["state"] not in {"applied", "prepared"}:
            raise ResourceTransactionError("invalid_checkpoint", "Checkpoint já restaurado.")
        scene_name, scene = self._path(manifest["scene"], {".tscn"})
        _, resource = self._path(manifest["resource"], {".tscn", ".tres"})
        self._state(scene_name, state_getter())
        base = self._work_dir()
        lock = self._lock(base)
        try:
            folder, manifest = self._checkpoint(checkpoint_id, "uid")
            if manifest["state"] not in {"applied", "prepared"}:
                raise ResourceTransactionError("invalid_checkpoint", "Checkpoint já restaurado.")
            self._state(scene_name, state_getter())
            if expected_current_sha256 != manifest["after_sha256"] or _sha(self._read(scene)) != expected_current_sha256 or _sha(self._read(resource)) != manifest["source_sha256"]:
                raise ResourceTransactionError("hash_conflict", "Cena ou recurso mudou; restauração recusada.")
            before = (folder / "before.tscn").read_bytes()
            if _sha(before) != manifest["before_sha256"]:
                raise ResourceTransactionError("checkpoint_corrupt", "Cópia anterior não confere.")
            temp = scene.with_name(scene.name + ".ai_mcp_restore_" + checkpoint_id + ".tmp")
            try:
                with temp.open("xb") as stream:
                    stream.write(before)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp, scene)
            finally:
                temp.unlink(missing_ok=True)
            if _sha(self._read(scene)) != manifest["before_sha256"]:
                raise ResourceTransactionError("restore_failed", "Arquivo restaurado não confere.")
            manifest["state"] = "restored"
            self._manifest_write(folder, manifest)
        finally:
            lock.unlink(missing_ok=True)
        self.checkpoints.pop(checkpoint_id, None)
        return {"scene_path": scene_name, "sha256": manifest["before_sha256"], "restored": True}

    def promote_mesh_library(self, stage_id: str, staged_sha256: str, scene_raw: str, scene_sha256: str, output_raw: str, state_getter) -> dict:
        scene_name, scene = self._path(scene_raw, {".tscn"})
        output_name, output = self._new_path(output_raw, ".tres")
        stage = self._stage(stage_id)
        if not all(isinstance(value, str) and HEX_SHA.fullmatch(value) for value in (staged_sha256, scene_sha256)):
            raise ResourceTransactionError("invalid_hash", "Hashes inválidos.")
        self._state(scene_name, state_getter())
        base = self._work_dir()
        lock = self._lock(base)
        try:
            self._state(scene_name, state_getter())
            self._new_path(output_raw, ".tres")
            if _sha(self._read(scene)) != scene_sha256 or _sha(self._read(stage)) != staged_sha256:
                raise ResourceTransactionError("hash_conflict", "Cena ou candidato mudou.")
            checkpoint_id = uuid.uuid4().hex
            folder = base / checkpoint_id
            folder.mkdir()
            manifest = {"owner": self.owner, "kind": "mesh_library", "scene": scene_name, "scene_sha256": scene_sha256, "output": output_name, "after_sha256": staged_sha256, "state": "prepared"}
            self._manifest_write(folder, manifest)
            self.checkpoints[checkpoint_id] = folder
            with stage.open("rb") as stream:
                if not stream.read(256).startswith(b'[gd_resource type="MeshLibrary"'):
                    raise ResourceTransactionError("invalid_stage", "Candidato não é MeshLibrary textual.")
            try:
                os.link(stage, output)
            except FileExistsError as exc:
                raise ResourceTransactionError("output_conflict", "Destino foi criado por outra operação.") from exc
            except OSError as exc:
                raise ResourceTransactionError("promotion_failed", "Não foi possível criar MeshLibrary exclusivamente.") from exc
            try:
                stage.unlink()
                if _sha(self._read(output)) != staged_sha256:
                    raise ResourceTransactionError("postcondition_failed", "MeshLibrary criada não confere.")
                manifest["state"] = "applied"
                self._manifest_write(folder, manifest)
            except (OSError, ResourceTransactionError) as exc:
                raise ResourceTransactionError("postcondition_failed", "MeshLibrary criada, mas finalização falhou; checkpoint preservado.", {"checkpoint_id": checkpoint_id}) from exc
        finally:
            lock.unlink(missing_ok=True)
        return {"checkpoint_id": checkpoint_id, "scene_path": scene_name, "output_path": output_name, "sha256": staged_sha256, "rollback": "hash_and_reference_guarded"}

    def rollback_mesh_library(self, checkpoint_id: str, expected_current_sha256: str, state_getter) -> dict:
        if not isinstance(expected_current_sha256, str) or not HEX_SHA.fullmatch(expected_current_sha256):
            raise ResourceTransactionError("invalid_hash", "SHA-256 atual inválido.")
        folder, manifest = self._checkpoint(checkpoint_id, "mesh_library")
        if manifest["state"] not in {"prepared", "applied"}:
            raise ResourceTransactionError("invalid_checkpoint", "Checkpoint já restaurado.")
        scene_name, scene = self._path(manifest["scene"], {".tscn"})
        output_name, output = self._path(manifest["output"], {".tres"})
        self._state(scene_name, state_getter())
        base = self._work_dir()
        lock = self._lock(base)
        try:
            folder, manifest = self._checkpoint(checkpoint_id, "mesh_library")
            if manifest["state"] not in {"prepared", "applied"}:
                raise ResourceTransactionError("invalid_checkpoint", "Checkpoint já restaurado.")
            self._state(scene_name, state_getter())
            if expected_current_sha256 != manifest["after_sha256"] or _sha(self._read(output)) != expected_current_sha256 or _sha(self._read(scene)) != manifest["scene_sha256"]:
                raise ResourceTransactionError("hash_conflict", "Cena ou MeshLibrary mudou.")
            content = self._read(output).decode("utf-8")
            header = HEADER.match(content)
            uid = header.group(1) if header else None
            consumers = self._references(output_name, uid)
            if consumers:
                raise ResourceTransactionError("resource_referenced", "MeshLibrary já possui consumidores em disco.")
            output.unlink()
            manifest["state"] = "restored"
            self._manifest_write(folder, manifest)
        finally:
            lock.unlink(missing_ok=True)
        self.checkpoints.pop(checkpoint_id, None)
        return {"restored": True, "output_path": output_name}
