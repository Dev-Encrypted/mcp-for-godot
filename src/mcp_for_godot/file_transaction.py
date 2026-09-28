"""Transacoes conservadoras para um script GDScript do projeto conectado.

O validador roda num projeto minimo descartavel. Ele nunca abre project.godot,
addons ou scripts @tool do projeto do usuario.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid


class _ProjectLock:
    """Trava de byte do SO, liberada automaticamente ao encerrar o processo."""

    def __init__(self, path: Path, error_type, owner: str):
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
            raise error_type("invalid_checkpoint", "Arquivo de trava vinculado.")
        try:
            self.handle = path.open("a+b")
            self.handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if hasattr(self, "handle"):
                self.handle.close()
            raise error_type("transaction_busy", "Outra transacao usa o projeto; a trava do SO sera liberada quando o processo terminar.") from exc
        # O arquivo permanece vazio; a posse pertence ao handle do SO.

    def unlink(self, missing_ok: bool = True) -> None:
        if self.handle.closed:
            return
        try:
            self.handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.handle.close()


MAX_SCRIPT_BYTES = 131_072
MAX_PREVIEWS = 16
PREVIEW_TTL_SECONDS = 300
HEX_SHA = re.compile(r"[0-9a-f]{64}\Z")


class TransactionError(Exception):
    def __init__(self, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FileTransactions:
    def __init__(self, project: Path, godot: Path, owner: str):
        self.project = project.resolve(strict=True)
        self.godot = godot.resolve(strict=True)
        self.owner = owner
        self.previews: dict[str, dict] = {}
        self.checkpoints: dict[str, Path] = {}

    def _target(self, raw: str) -> tuple[str, Path]:
        if not isinstance(raw, str) or not raw.startswith("res://") or "\\" in raw or "\x00" in raw:
            raise TransactionError("invalid_path", "Use caminho res:// de script.")
        relative = raw[6:]
        parts = relative.split("/")
        if not parts or any(not p or p in {".", ".."} or p.startswith(".") or ":" in p for p in parts):
            raise TransactionError("invalid_path", "Caminho oculto ou traversal recusado.")
        if Path(relative).suffix.lower() != ".gd":
            raise TransactionError("unsupported_type", "Esta transacao aceita somente .gd.")
        original = self.project / relative
        ancestor = self.project
        for part in parts:
            ancestor = ancestor / part
            if ancestor.is_symlink() or getattr(ancestor, "is_junction", lambda: False)():
                raise TransactionError("invalid_path", "Link de arquivo ou diretorio recusado.")
        path = original.resolve(strict=False)
        if not path.is_relative_to(self.project) or not path.parent.is_dir():
            raise TransactionError("invalid_path", "Script fora do projeto ou diretorio inexistente.")
        return "res://" + Path(relative).as_posix(), path

    def _state(self, path: str, state: dict) -> None:
        if not isinstance(state, dict) or not isinstance(state.get("project_path"), str) or Path(state["project_path"]).resolve() != self.project:
            raise TransactionError("editor_unavailable", "Editor do projeto nao confirmado.")
        opened = state.get("open_scripts")
        if not isinstance(opened, list) or any(not isinstance(x, str) for x in opened):
            raise TransactionError("editor_state_unknown", "Editor nao informou scripts abertos.")
        if path in opened:
            raise TransactionError("script_open", "Feche o script no editor antes de aplicar ou reverter; o buffer pode nao estar salvo.")
        if state.get("playing"):
            raise TransactionError("scene_playing", "Pare a execucao antes de alterar scripts.")

    def _read(self, path: Path) -> bytes | None:
        if not path.exists():
            return None
        if not path.is_file():
            raise TransactionError("invalid_path", "O alvo nao e arquivo regular.")
        if path.stat().st_size > MAX_SCRIPT_BYTES:
            raise TransactionError("file_too_large", "Script maior que 128 KiB.")
        return path.read_bytes()

    def _dir(self) -> Path:
        path = self.project / ".godot" / "ai_mcp" / "transactions"
        probe = self.project
        for part in (".godot", "ai_mcp", "transactions"):
            probe = probe / part
            if probe.exists() and (probe.is_symlink() or getattr(probe, "is_junction", lambda: False)() or not probe.resolve().is_relative_to(self.project)):
                raise TransactionError("invalid_checkpoint", "Pasta de checkpoint usa link ou sai do projeto.")
        path.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project):
            raise TransactionError("invalid_checkpoint", "Checkpoint fora do projeto.")
        return path

    def _lock(self, base: Path) -> _ProjectLock:
        return _ProjectLock(base / "project.lock", TransactionError, self.owner)

    def _write_manifest(self, folder: Path, manifest: dict) -> None:
        temporary = folder / ("manifest-" + uuid.uuid4().hex + ".tmp")
        try:
            with temporary.open("xb") as stream:
                stream.write(json.dumps(manifest, separators=(",", ":")).encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, folder / "manifest.json")
        finally:
            temporary.unlink(missing_ok=True)

    def _checkpoint(self, checkpoint_id: str) -> tuple[Path, dict]:
        if not isinstance(checkpoint_id, str) or re.fullmatch(r"[0-9a-f]{32}", checkpoint_id) is None:
            raise TransactionError("invalid_checkpoint", "checkpoint_id invalido.")
        base = self._dir()
        folder = base / checkpoint_id
        manifest_path = folder / "manifest.json"
        if (not folder.is_dir() or folder.is_symlink() or getattr(folder, "is_junction", lambda: False)()
                or manifest_path.is_symlink() or getattr(manifest_path, "is_junction", lambda: False)()):
            raise TransactionError("invalid_checkpoint", "Pasta ou manifesto de checkpoint invalido.")
        try:
            if manifest_path.stat().st_size > 4096:
                raise TransactionError("checkpoint_corrupt", "Manifesto excede limite.")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise TransactionError("checkpoint_corrupt", "Manifesto de checkpoint ilegivel.") from exc
        keys = {"owner", "path", "before_sha256", "after_sha256", "state"}
        if not isinstance(manifest, dict) or set(manifest) != keys or not isinstance(manifest["owner"], str) or len(manifest["owner"]) > 128 or manifest["state"] not in {"prepared", "applied", "rolled_back"} or not isinstance(manifest["after_sha256"], str) or not HEX_SHA.fullmatch(manifest["after_sha256"]) or (manifest["before_sha256"] is not None and (not isinstance(manifest["before_sha256"], str) or not HEX_SHA.fullmatch(manifest["before_sha256"]))):
            raise TransactionError("checkpoint_corrupt", "Manifesto de checkpoint invalido.")
        self._target(manifest["path"])
        backup = folder / "before.gd"
        if backup.is_symlink() or getattr(backup, "is_junction", lambda: False)():
            raise TransactionError("checkpoint_corrupt", "Copia anterior vinculada.")
        if manifest["before_sha256"] is None:
            if backup.exists():
                raise TransactionError("checkpoint_corrupt", "Checkpoint de criacao possui copia inesperada.")
        elif not backup.is_file() or _sha(self._read(backup) or b"") != manifest["before_sha256"]:
            raise TransactionError("checkpoint_corrupt", "Copia anterior nao confere com manifesto.")
        return folder, manifest

    def list_checkpoints(self, limit: int = 64) -> list[dict]:
        if type(limit) is not int or not 1 <= limit <= 128:
            raise TransactionError("invalid_query", "limit deve estar entre 1 e 128.")
        base = self._dir()
        entries = [entry.name for entry in base.iterdir() if re.fullmatch(r"[0-9a-f]{32}", entry.name)]
        if len(entries) > 1024:
            raise TransactionError("checkpoint_limit", "Muitos checkpoints; revise a pasta de transacoes.")
        result = []
        for checkpoint_id in sorted(entries, reverse=True):
            folder = base / checkpoint_id
            if not folder.is_dir() or folder.is_symlink() or getattr(folder, "is_junction", lambda: False)():
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} vinculado ou invalido.")
            peek = folder / "manifest.json"
            if not peek.is_file() or peek.is_symlink() or getattr(peek, "is_junction", lambda: False)() or peek.stat().st_size > 4096:
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} invalido.")
            try:
                kind_hint = json.loads(peek.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} invalido.") from exc
            if not isinstance(kind_hint, dict):
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} invalido.")
            if "scene" in kind_hint or kind_hint.get("kind") == "texture_import":
                continue
            if "path" not in kind_hint:
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} sem tipo conhecido.")
            try:
                _, manifest = self._checkpoint(checkpoint_id)
            except TransactionError as exc:
                if exc.code == "invalid_checkpoint":
                    raise
                raise TransactionError("checkpoint_corrupt", f"Checkpoint {checkpoint_id} invalido.") from exc
            name, target = self._target(manifest["path"])
            current = self._read(target)
            actual = None if current is None else _sha(current)
            status = "recoverable" if actual == manifest["after_sha256"] else "already_restored" if actual == manifest["before_sha256"] else "conflict"
            result.append({"checkpoint_id": checkpoint_id, "kind": "script", "path": name, "state": manifest["state"], "before_sha256": manifest["before_sha256"], "after_sha256": manifest["after_sha256"], "actual_sha256": actual, "recovery": status})
            if len(result) >= limit:
                break
        return result

    def _assert_unreferenced(self, script_name: str, state: dict) -> None:
        if state.get("unsaved_scenes"):
            raise TransactionError("unsaved_scene", "Salve ou reverta cenas pendentes antes de remover script criado.")
        relative = script_name.removeprefix("res://")
        script = self.project / relative
        uid_path = script.with_name(script.name + ".uid")
        if uid_path.exists():
            raise TransactionError("script_sidecar_present", "Sidecar UID do script existe; remocao automatica exige revisao separada.")
        needles = (script_name.encode("utf-8"), relative.encode("utf-8"))
        seen = 0
        total = 0
        hits: list[str] = []
        for base, directories, files in os.walk(self.project, followlinks=False):
            folder = Path(base)
            kept = []
            for directory in directories:
                child = folder / directory
                if directory in {".godot", ".git", "node_modules", "__pycache__"}:
                    continue
                if child.is_symlink() or getattr(child, "is_junction", lambda: False)():
                    raise TransactionError("dependency_scan_incomplete", "Diretorio vinculado impede varredura de consumidores.")
                kept.append(directory)
            directories[:] = kept
            for file_name in files:
                candidate = folder / file_name
                if candidate == script or candidate.suffix.lower() not in {".tscn", ".tres", ".gd", ".gdshader", ".godot"}:
                    continue
                if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)():
                    raise TransactionError("dependency_scan_incomplete", "Arquivo vinculado impede varredura de consumidores.")
                seen += 1
                size = candidate.stat().st_size
                total += size
                if seen > 5000 or size > 1_048_576 or total > 67_108_864:
                    raise TransactionError("dependency_scan_incomplete", "Varredura de consumidores excedeu limites.")
                data = candidate.read_bytes()
                if any(needle in data for needle in needles):
                    hits.append(candidate.relative_to(self.project).as_posix())
                    if len(hits) >= 5:
                        break
            if len(hits) >= 5:
                break
        if hits:
            raise TransactionError("script_referenced", "Script criado possui consumidores conhecidos; desfaça associação e salve a cena antes de restaurar.", {"files": hits})

    def preview(self, raw_path: str, expected_sha256: str | None, content: str, state: dict) -> dict:
        path_name, target = self._target(raw_path)
        if not isinstance(content, str):
            raise TransactionError("invalid_content", "content deve ser texto UTF-8.")
        if "\x00" in content or "\r" in content:
            raise TransactionError("invalid_content", "NUL e CR nao sao permitidos; use LF.")
        try:
            new = content.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise TransactionError("invalid_encoding", "content nao e UTF-8 valido.") from exc
        if len(new) > MAX_SCRIPT_BYTES:
            raise TransactionError("file_too_large", "Script maior que 128 KiB.")
        if "@tool" in content or re.search(r"\b(preload|load|static|_static_init|class_name)\b", content) or re.search(r"extends\s+['\"]", content):
            raise TransactionError("unsafe_validation", "Script com inicializador estatico, @tool ou dependencia de parse exige fluxo dedicado.")
        self._state(path_name, state)
        old = self._read(target)
        expected = None if old is None else _sha(old)
        if old is None:
            if expected_sha256 is not None:
                raise TransactionError("hash_conflict", "Arquivo nao existe; expected_sha256 deve ser null.")
        elif not isinstance(expected_sha256, str) or not HEX_SHA.fullmatch(expected_sha256) or expected_sha256 != expected:
            raise TransactionError("hash_conflict", "SHA-256 do script mudou.", {"actual_sha256": expected})
        try:
            old_text = "" if old is None else old.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise TransactionError("invalid_encoding", "Script existente nao e UTF-8.") from exc
        diff = "".join(difflib.unified_diff(old_text.splitlines(keepends=True), content.splitlines(keepends=True), fromfile=path_name + ":before", tofile=path_name + ":after"))
        now = time.monotonic()
        self.previews = {key: value for key, value in self.previews.items() if now - value["created"] <= PREVIEW_TTL_SECONDS}
        if len(self.previews) >= MAX_PREVIEWS:
            raise TransactionError("preview_limit", "Limite de previews pendentes nesta instancia.")
        preview_id = uuid.uuid4().hex
        self.previews[preview_id] = {"path": path_name, "old_sha256": expected, "new": new, "new_sha256": _sha(new), "created": now}
        return {"preview_id": preview_id, "path": path_name, "old_sha256": expected, "new_sha256": _sha(new), "bytes": len(new), "diff": diff[:32768], "diff_truncated": len(diff) > 32768, "validation": "pending_disposable_copy", "note": "Script executavel quando associado/rodado; uso exige permissao explicita."}

    def _validate(self, script: bytes, work: Path) -> dict:
        work.mkdir(parents=True, exist_ok=False)
        (work / "project.godot").write_text('config_version=5\n[application]\nconfig/name="MCP for Godot script validation"\n', encoding="utf-8")
        (work / "candidate.gd").write_bytes(script)
        try:
            result = subprocess.run([str(self.godot), "--headless", "--path", str(work), "--check-only", "--script", "res://candidate.gd"], cwd=work, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise TransactionError("validation_unavailable", "Godot nao concluiu validacao na copia descartavel.") from exc
        output = (result.stdout + "\n" + result.stderr)[-8192:]
        if result.returncode != 0 or "ERROR" in output.upper() or "PARSE ERROR" in output.upper():
            raise TransactionError("validation_failed", "Godot recusou o script na copia descartavel.", {"exit_code": result.returncode, "output": output})
        return {"method": "headless_disposable_check_only", "exit_code": result.returncode}

    def apply(self, preview_id: str, state_getter) -> dict:
        if not isinstance(preview_id, str) or not re.fullmatch(r"[0-9a-f]{32}", preview_id):
            raise TransactionError("invalid_preview", "preview_id invalido.")
        item = self.previews.get(preview_id)
        if item is None or time.monotonic() - item["created"] > PREVIEW_TTL_SECONDS:
            raise TransactionError("invalid_preview", "Preview desconhecido nesta instancia MCP.")
        name, target = self._target(item["path"])
        self._state(name, state_getter())
        old = self._read(target)
        if (None if old is None else _sha(old)) != item["old_sha256"]:
            raise TransactionError("hash_conflict", "Script mudou depois do preview.")
        base = self._dir()
        validation = base / ("validate-" + uuid.uuid4().hex)
        try:
            validated = self._validate(item["new"], validation)
        finally:
            if validation.exists() and not validation.is_symlink() and not getattr(validation, "is_junction", lambda: False)() and validation.resolve().is_relative_to(base.resolve()):
                shutil.rmtree(validation)
        lock = self._lock(base)
        try:
            # Releitura sob trava, depois de validar e consultar o editor outra vez.
            self._state(name, state_getter())
            current = self._read(target)
            if (None if current is None else _sha(current)) != item["old_sha256"]:
                raise TransactionError("hash_conflict", "Script mudou durante a validacao.")
            checkpoint_id = uuid.uuid4().hex
            folder = base / checkpoint_id
            folder.mkdir()
            if current is not None:
                (folder / "before.gd").write_bytes(current)
            manifest = {"owner": self.owner, "path": name, "before_sha256": item["old_sha256"], "after_sha256": item["new_sha256"], "state": "prepared"}
            self._write_manifest(folder, manifest)
            self.checkpoints[checkpoint_id] = folder
            tmp = target.with_name(target.name + ".ai_mcp_" + checkpoint_id + ".tmp")
            try:
                with tmp.open("xb") as stream:
                    stream.write(item["new"])
                    stream.flush()
                    os.fsync(stream.fileno())
                if current is None:
                    # Criacao atomica sem sobrescrever arquivo surgido apos o recheck.
                    os.link(tmp, target)
                else:
                    os.replace(tmp, target)
            finally:
                tmp.unlink(missing_ok=True)
            written = self._read(target)
            if written is None or _sha(written) != item["new_sha256"]:
                raise TransactionError("write_verification_failed", "Arquivo aplicado nao confere; checkpoint preparado permite restauracao.", {"checkpoint_id": checkpoint_id})
            manifest["state"] = "applied"
            self._write_manifest(folder, manifest)
        except OSError as exc:
            raise TransactionError("write_failed", "Troca atomica ou registro final falhou; checkpoint preservado.", {"checkpoint_id": locals().get("checkpoint_id")}) from exc
        finally:
            lock.unlink(missing_ok=True)
        self.previews.pop(preview_id, None)
        return {"checkpoint_id": checkpoint_id, "path": name, "before_sha256": item["old_sha256"], "after_sha256": item["new_sha256"], "validation": validated, "rollback": "hash_guarded"}

    def rollback(self, checkpoint_id: str, expected_current_sha256: str, state_getter) -> dict:
        if not isinstance(checkpoint_id, str) or not re.fullmatch(r"[0-9a-f]{32}", checkpoint_id):
            raise TransactionError("invalid_checkpoint", "checkpoint_id invalido.")
        folder, manifest = self._checkpoint(checkpoint_id)
        if manifest["state"] not in {"applied", "prepared"}:
            raise TransactionError("invalid_checkpoint", "Checkpoint ja revertido.")
        name, target = self._target(manifest["path"])
        self._state(name, state_getter())
        lock = self._lock(self._dir())
        try:
            folder, manifest = self._checkpoint(checkpoint_id)
            if manifest["state"] not in {"applied", "prepared"}:
                raise TransactionError("invalid_checkpoint", "Checkpoint ja revertido.")
            state = state_getter()
            self._state(name, state)
            current = self._read(target)
            actual = None if current is None else _sha(current)
            if not isinstance(expected_current_sha256, str) or expected_current_sha256 != manifest["after_sha256"] or actual != expected_current_sha256:
                raise TransactionError("hash_conflict", "Script mudou; restauracao recusada.", {"actual_sha256": actual})
            before_hash = manifest["before_sha256"]
            if before_hash is None:
                self._assert_unreferenced(name, state)
                target.unlink()
            else:
                before = (folder / "before.gd").read_bytes()
                if _sha(before) != before_hash:
                    raise TransactionError("checkpoint_corrupt", "Copia anterior nao confere com manifesto.")
                tmp = target.with_name(target.name + ".ai_mcp_restore_" + checkpoint_id + ".tmp")
                try:
                    with tmp.open("xb") as stream:
                        stream.write(before)
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.replace(tmp, target)
                finally:
                    tmp.unlink(missing_ok=True)
            verify = self._read(target)
            if (None if verify is None else _sha(verify)) != before_hash:
                raise TransactionError("restore_failed", "Restauracao nao passou na verificacao de hash.")
            manifest["state"] = "rolled_back"
            self._write_manifest(folder, manifest)
            return {"path": name, "restored_sha256": before_hash, "checkpoint_id": checkpoint_id, "verified": True}
        finally:
            lock.unlink(missing_ok=True)
