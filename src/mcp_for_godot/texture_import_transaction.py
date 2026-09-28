"""Transacao restrita de opcoes de importacao de uma textura PNG existente.

O editor produz o ConfigFile e executa a importacao. Este modulo guarda os
bytes anteriores do sidecar e nunca manipula .godot/imported diretamente.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import struct
import time
import uuid

from .file_transaction import _ProjectLock


HEX = re.compile(r"[0-9a-f]{64}\Z")
ID = re.compile(r"[0-9a-f]{32}\Z")
MAX_PNG = 4_194_304
MAX_SIDECAR = 65_536
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
OPTION_KEYS = {"compress/mode", "mipmaps/generate", "process/fix_alpha_border", "process/size_limit"}


class TextureImportError(Exception):
    def __init__(self, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TextureImportTransactions:
    def __init__(self, project: Path, owner: str):
        self.project = project.resolve(strict=True)
        self.owner = owner
        self.previews: dict[str, dict] = {}

    def _source(self, raw: str) -> tuple[str, Path, Path]:
        if not isinstance(raw, str) or len(raw) > 512 or not raw.startswith("res://") or "\\" in raw or "\x00" in raw:
            raise TextureImportError("invalid_path", "Use caminho res:// PNG local.")
        parts = raw[6:].split("/")
        if not parts or any(not p or p in {".", ".."} or p.startswith(".") or ":" in p for p in parts) or not parts[-1].lower().endswith(".png"):
            raise TextureImportError("invalid_path", "Caminho PNG invalido ou oculto.")
        path = self.project
        for part in parts:
            path = path / part
            if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                raise TextureImportError("invalid_path", "Link ou junction recusado.")
        path = path.resolve(strict=False)
        if not path.is_relative_to(self.project) or not path.is_file():
            raise TextureImportError("invalid_path", "PNG fora do projeto ou inexistente.")
        sidecar = path.with_name(path.name + ".import")
        if sidecar.is_symlink() or getattr(sidecar, "is_junction", lambda: False)():
            raise TextureImportError("invalid_path", "Sidecar vinculado recusado.")
        return "res://" + "/".join(parts), path, sidecar

    def _read(self, path: Path, limit: int) -> bytes | None:
        if not path.exists():
            return None
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.is_file() or path.stat().st_size > limit:
            raise TextureImportError("invalid_file", "Arquivo vinculado, nao regular ou acima do limite.")
        return path.read_bytes()

    def _png(self, data: bytes) -> tuple[int, int]:
        if len(data) < 33 or data[:8] != PNG_MAGIC or data[12:16] != b"IHDR" or struct.unpack(">I", data[8:12])[0] != 13:
            raise TextureImportError("invalid_png", "Cabecalho PNG invalido.")
        width, height = struct.unpack(">II", data[16:24])
        if not 1 <= width <= 2048 or not 1 <= height <= 2048 or data[24] not in {1, 2, 4, 8, 16} or data[25] not in {0, 2, 3, 4, 6}:
            raise TextureImportError("unsupported_png", "Dimensoes ou formato PNG fora do escopo.")
        return width, height

    def _options(self, options: dict) -> dict:
        if not isinstance(options, dict) or not options or set(options) - OPTION_KEYS:
            raise TextureImportError("invalid_options", "Opcoes fora da lista permitida.")
        for key, value in options.items():
            if key == "compress/mode" and (type(value) is not int or value not in {0, 1}):
                raise TextureImportError("invalid_options", "compress/mode aceita 0 ou 1.")
            if key in {"mipmaps/generate", "process/fix_alpha_border"} and type(value) is not bool:
                raise TextureImportError("invalid_options", f"{key} exige booleano.")
            if key == "process/size_limit" and (type(value) is not int or value not in {0, 256, 512, 1024, 2048}):
                raise TextureImportError("invalid_options", "process/size_limit fora da lista.")
        return dict(sorted(options.items()))

    def _state(self, state: dict) -> None:
        if not isinstance(state, dict) or not isinstance(state.get("project_path"), str) or Path(state["project_path"]).resolve() != self.project:
            raise TextureImportError("editor_unavailable", "Editor do projeto nao confirmado.")
        if not isinstance(state.get("unsaved_scenes"), list) or state["unsaved_scenes"] or state.get("playing"):
            raise TextureImportError("editor_busy", "Pare o Play e salve cenas pendentes antes de importar.")

    def _base(self) -> Path:
        path = self.project
        for part in (".godot", "ai_mcp", "transactions"):
            path /= part
            if path.exists() and (path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.resolve().is_relative_to(self.project)):
                raise TextureImportError("invalid_checkpoint", "Pasta de checkpoint insegura.")
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _write_manifest(self, folder: Path, value: dict) -> None:
        temp = folder / ("manifest." + uuid.uuid4().hex + ".tmp")
        try:
            with temp.open("xb") as stream:
                stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, folder / "manifest.json")
        finally:
            temp.unlink(missing_ok=True)

    def _replace(self, path: Path, data: bytes | None) -> None:
        if data is None:
            path.unlink(missing_ok=True)
            return
        temp = path.with_name(path.name + ".ai-mcp-" + uuid.uuid4().hex)
        try:
            with temp.open("xb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)

    def preview(self, raw: str, expected_source: str, expected_import: str | None, options: dict, editor_prepare, state: dict) -> dict:
        self._state(state)
        name, source, sidecar = self._source(raw)
        if not isinstance(expected_source, str) or not HEX.fullmatch(expected_source) or (expected_import is not None and (not isinstance(expected_import, str) or not HEX.fullmatch(expected_import))):
            raise TextureImportError("invalid_hash", "SHA-256 esperado invalido.")
        source_bytes = self._read(source, MAX_PNG)
        assert source_bytes is not None
        dimensions = self._png(source_bytes)
        before = self._read(sidecar, MAX_SIDECAR)
        if _sha(source_bytes) != expected_source or (None if before is None else _sha(before)) != expected_import:
            raise TextureImportError("hash_conflict", "PNG ou sidecar mudou desde a leitura.")
        normalized = self._options(options)
        prepared = editor_prepare({"path": name, "source_sha256": expected_source, "import_sha256": expected_import, "options": normalized})
        if prepared.get("status") != "ok" or not isinstance(prepared.get("candidate_text"), str):
            raise TextureImportError("prepare_failed", "Editor nao gerou ConfigFile de importacao.", {"editor_result": prepared})
        candidate = prepared["candidate_text"].encode("utf-8")
        if not candidate or len(candidate) > MAX_SIDECAR or candidate == before:
            raise TextureImportError("no_change", "Opcoes nao mudaram ou sidecar excede limite.")
        preview_id = uuid.uuid4().hex
        self.previews = {key: value for key, value in self.previews.items() if time.monotonic() - value["created"] <= 300}
        if len(self.previews) >= 16:
            self.previews.pop(next(iter(self.previews)))
        self.previews[preview_id] = {"created": time.monotonic(), "path": name, "source": expected_source, "before": expected_import, "candidate": candidate, "options": normalized}
        return {"preview_id": preview_id, "path": name, "source_sha256": expected_source, "import_sha256_before": expected_import, "candidate_sha256": _sha(candidate), "dimensions": list(dimensions), "options": normalized, "previous_importer": prepared.get("previous_importer"), "previous_uid": prepared.get("previous_uid"), "previous_dependencies": prepared.get("previous_dependencies", []), "load_performed": False, "checkpoint_on_apply": True}

    def apply(self, preview_id: str, state_getter, editor_reimport) -> dict:
        if not isinstance(preview_id, str) or preview_id not in self.previews:
            raise TextureImportError("unknown_preview", "Previa desconhecida ou expirada.")
        preview = self.previews[preview_id]
        if time.monotonic() - preview["created"] > 300:
            self.previews.pop(preview_id, None)
            raise TextureImportError("expired_preview", "Previa expirou.")
        base = self._base()
        lock = _ProjectLock(base / "project.lock", TextureImportError, self.owner)
        checkpoint_id = None
        try:
            self._state(state_getter())
            name, source, sidecar = self._source(preview["path"])
            source_bytes = self._read(source, MAX_PNG)
            before = self._read(sidecar, MAX_SIDECAR)
            if source_bytes is None or _sha(source_bytes) != preview["source"] or (None if before is None else _sha(before)) != preview["before"]:
                raise TextureImportError("hash_conflict", "PNG ou sidecar mudou antes da aplicacao.")
            checkpoint_id = uuid.uuid4().hex
            folder = base / checkpoint_id
            folder.mkdir(mode=0o700)
            if before is not None:
                with (folder / "before.import").open("xb") as stream:
                    stream.write(before)
                    stream.flush()
                    os.fsync(stream.fileno())
            manifest = {"kind": "texture_import", "owner": self.owner, "path": name, "source_sha256": preview["source"], "before_sha256": preview["before"], "staged_sha256": _sha(preview["candidate"]), "after_sha256": None, "compensated_sha256": None, "options": preview["options"], "state": "prepared"}
            self._write_manifest(folder, manifest)
            self._replace(sidecar, preview["candidate"])
            reply = editor_reimport({"path": name, "source_sha256": preview["source"], "expected_import_sha256": manifest["staged_sha256"], "expected_options": preview["options"]})
            after = self._read(sidecar, MAX_SIDECAR)
            if after is not None:
                manifest["after_sha256"] = _sha(after)
            confirmed = (reply.get("status") == "ok" and after is not None and reply.get("import_sha256") == manifest["after_sha256"] and _sha(self._read(source, MAX_PNG) or b"") == manifest["source_sha256"])
            manifest["state"] = "applied" if confirmed else "uncertain"
            self._write_manifest(folder, manifest)
            if not confirmed:
                raise TextureImportError("import_failed", "Reimportacao nao foi confirmada; checkpoint preservado.", {"checkpoint_id": checkpoint_id, "editor_result": reply})
            self.previews.pop(preview_id, None)
            return {"checkpoint_id": checkpoint_id, "path": name, "source_sha256": preview["source"], "before_sha256": preview["before"], "after_sha256": manifest["after_sha256"], "import": reply}
        except TextureImportError:
            raise
        except Exception as exc:
            raise TextureImportError("import_uncertain", "Falha apos preparo; consulte checkpoint antes de recuperar.", {"checkpoint_id": checkpoint_id}) from exc
        finally:
            lock.unlink()

    def _checkpoint(self, checkpoint_id: str) -> tuple[Path, dict, Path, Path]:
        if not isinstance(checkpoint_id, str) or not ID.fullmatch(checkpoint_id):
            raise TextureImportError("invalid_checkpoint", "checkpoint_id invalido.")
        folder = self._base() / checkpoint_id
        manifest_path = folder / "manifest.json"
        if not folder.is_dir() or folder.is_symlink() or getattr(folder, "is_junction", lambda: False)() or not manifest_path.is_file() or manifest_path.is_symlink() or manifest_path.stat().st_size > 4096:
            raise TextureImportError("invalid_checkpoint", "Checkpoint inexistente ou vinculado.")
        try:
            value = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise TextureImportError("checkpoint_corrupt", "Manifesto ilegivel.") from exc
        expected_keys = {"kind", "owner", "path", "source_sha256", "before_sha256", "staged_sha256", "after_sha256", "compensated_sha256", "options", "state"}
        if not isinstance(value, dict) or set(value) != expected_keys or value["kind"] != "texture_import" or not isinstance(value["owner"], str) or len(value["owner"]) > 128 or value["state"] not in {"prepared", "applied", "uncertain", "rollback_prepared", "rolled_back"} or any(not isinstance(value[k], str) or not HEX.fullmatch(value[k]) for k in ("source_sha256", "staged_sha256")) or any(value[k] is not None and (not isinstance(value[k], str) or not HEX.fullmatch(value[k])) for k in ("before_sha256", "after_sha256", "compensated_sha256")):
            raise TextureImportError("checkpoint_corrupt", "Manifesto invalido.")
        self._options(value["options"])
        _, source, sidecar = self._source(value["path"])
        backup = folder / "before.import"
        if backup.is_symlink() or getattr(backup, "is_junction", lambda: False)():
            raise TextureImportError("checkpoint_corrupt", "Backup vinculado.")
        before = self._read(backup, MAX_SIDECAR)
        if (None if before is None else _sha(before)) != value["before_sha256"]:
            raise TextureImportError("checkpoint_corrupt", "Backup nao confere.")
        return folder, value, source, sidecar

    def list_checkpoints(self, limit: int = 64) -> list[dict]:
        base = self._base()
        result = []
        for entry in sorted(base.iterdir(), key=lambda p: p.name, reverse=True):
            if not ID.fullmatch(entry.name):
                continue
            peek = entry / "manifest.json"
            if not peek.is_file() or peek.is_symlink() or peek.stat().st_size > 4096:
                raise TextureImportError("checkpoint_corrupt", "Checkpoint invalido.")
            try:
                hint = json.loads(peek.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise TextureImportError("checkpoint_corrupt", "Checkpoint ilegivel.") from exc
            if not isinstance(hint, dict):
                raise TextureImportError("checkpoint_corrupt", "Checkpoint invalido.")
            if hint.get("kind") != "texture_import":
                continue
            _, manifest, source, sidecar = self._checkpoint(entry.name)
            data = self._read(sidecar, MAX_SIDECAR)
            current = None if data is None else _sha(data)
            source_data = self._read(source, MAX_PNG)
            source_ok = source_data is not None and _sha(source_data) == manifest["source_sha256"]
            applied_match = current is not None and (current == manifest["staged_sha256"] or current == manifest["after_sha256"])
            recovery = "compensated" if source_ok and manifest["state"] == "rolled_back" and current == manifest["compensated_sha256"] else "recoverable" if source_ok and applied_match else "already_restored" if source_ok and current == manifest["before_sha256"] else "conflict"
            result.append({"checkpoint_id": entry.name, "kind": "texture_import", "path": manifest["path"], "state": manifest["state"], "source_sha256": manifest["source_sha256"], "before_sha256": manifest["before_sha256"], "after_sha256": manifest["after_sha256"], "compensated_sha256": manifest["compensated_sha256"], "actual_sha256": current, "recovery": recovery})
            if len(result) >= limit:
                break
        return result

    def rollback(self, checkpoint_id: str, expected_current_sha256: str | None, state_getter, editor_reimport, editor_prepare=None) -> dict:
        if expected_current_sha256 is not None and (not isinstance(expected_current_sha256, str) or not HEX.fullmatch(expected_current_sha256)):
            raise TextureImportError("invalid_hash", "Hash atual invalido.")
        base = self._base()
        lock = _ProjectLock(base / "project.lock", TextureImportError, self.owner)
        try:
            self._state(state_getter())
            folder, manifest, source, sidecar = self._checkpoint(checkpoint_id)
            source_data = self._read(source, MAX_PNG)
            if source_data is None or _sha(source_data) != manifest["source_sha256"]:
                raise TextureImportError("source_conflict", "PNG mudou; compensacao recusada.")
            current_data = self._read(sidecar, MAX_SIDECAR)
            current = None if current_data is None else _sha(current_data)
            if current != expected_current_sha256:
                raise TextureImportError("hash_conflict", "Sidecar mudou desde a leitura.", {"actual_sha256": current})
            if manifest["state"] == "rolled_back":
                raise TextureImportError("already_restored", "Checkpoint ja compensado.")
            recognized = current is not None and (current == manifest["staged_sha256"] or current == manifest["after_sha256"])
            if not recognized and manifest["state"] == "rollback_prepared" and current == manifest["before_sha256"]:
                recognized = True
            if not recognized and manifest["state"] in {"prepared", "uncertain"} and editor_prepare is not None and current is not None:
                # Crash no intervalo entre reimport_files e manifesto final: apenas
                # o hash explícito do chamador e ConfigFile equivalente permitem
                # recuperar sem aceitar uma edição externa de opções.
                inspected = editor_prepare({"path": manifest["path"], "source_sha256": manifest["source_sha256"], "import_sha256": current, "options": manifest["options"]})
                recognized = inspected.get("status") == "ok" and isinstance(inspected.get("candidate_text"), str) and _sha(inspected["candidate_text"].encode("utf-8")) == current
            if not recognized:
                raise TextureImportError("hash_conflict", "Sidecar nao corresponde ao estado aplicado conhecido.")
            before = self._read(folder / "before.import", MAX_SIDECAR)
            manifest["state"] = "rollback_prepared"
            self._write_manifest(folder, manifest)
            self._replace(sidecar, before)
            try:
                reply = editor_reimport({"path": manifest["path"], "source_sha256": manifest["source_sha256"], "expected_import_sha256": manifest["before_sha256"], "expected_options": None})
            except Exception as exc:
                raise TextureImportError("rollback_uncertain", "Compensacao pode estar incompleta; checkpoint preservado.", {"checkpoint_id": checkpoint_id}) from exc
            if reply.get("status") != "ok":
                raise TextureImportError("rollback_uncertain", "Compensacao nao foi confirmada; checkpoint preservado.", {"checkpoint_id": checkpoint_id, "editor_result": reply})
            final = self._read(sidecar, MAX_SIDECAR)
            if final is None or reply.get("import_sha256") != _sha(final) or _sha(self._read(source, MAX_PNG) or b"") != manifest["source_sha256"]:
                raise TextureImportError("rollback_uncertain", "Pos-condicao da compensacao divergiu; checkpoint preservado.", {"checkpoint_id": checkpoint_id})
            manifest["compensated_sha256"] = None if final is None else _sha(final)
            manifest["state"] = "rolled_back"
            self._write_manifest(folder, manifest)
            return {"checkpoint_id": checkpoint_id, "path": manifest["path"], "source_sha256": manifest["source_sha256"], "sidecar_sha256": None if final is None else _sha(final), "sidecar_bytes_restored": final == before, "cache_reimported_as_compensation": True, "import": reply}
        finally:
            lock.unlink()
