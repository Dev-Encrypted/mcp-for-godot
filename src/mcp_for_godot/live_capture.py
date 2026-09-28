"""Exporta e reabre uma captura limitada de observacao do editor Godot.

O comando export consulta somente as ferramentas de leitura da ponte local e
grava um arquivo dentro de .godot/ai_mcp/captures do projeto selecionado.
O comando inspect funciona sem editor nem jogo em execucao.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
import uuid
from typing import Any

from .server import GodotMCP, ToolError


CAPTURE_FORMAT = "mcp-for-godot-live-capture"
CAPTURE_VERSION = 1
MAX_CAPTURE_BYTES = 1_048_576
TIMELINE_LIMIT = 40


class CaptureError(ValueError):
    pass


def _canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _check_payload(payload: dict[str, Any]) -> None:
    if payload.get("format") != CAPTURE_FORMAT or payload.get("format_version") != CAPTURE_VERSION:
        raise CaptureError("Formato ou versao da captura incompativel.")
    snapshot = payload.get("snapshot")
    timeline = payload.get("timeline")
    if not isinstance(snapshot, dict) or not isinstance(timeline, dict):
        raise CaptureError("Snapshot ou timeline ausente.")
    sample = snapshot.get("sample")
    if snapshot.get("status") not in {"ok", "stale"} or not isinstance(sample, dict):
        raise CaptureError("A captura nao contem amostra validada.")
    if sample.get("schema_version") != 1 or sample.get("origin") != "runtime":
        raise CaptureError("Origem ou schema da amostra incompativel.")
    if not isinstance(sample.get("run_id"), str) or not isinstance(sample.get("sample_seq"), int) or not isinstance(sample.get("scene_path"), str) or not isinstance(sample.get("backend"), dict):
        raise CaptureError("Identidade ou contexto da amostra invalido.")
    if not isinstance(snapshot.get("session_id"), int) or not isinstance(snapshot.get("age_ms"), int) or not isinstance(snapshot.get("sequence_gaps"), int):
        raise CaptureError("Identidade ou validade da sessao invalida.")
    if timeline.get("schema_version") != 1 or timeline.get("origin") != "editor_receiver":
        raise CaptureError("Origem ou schema da timeline incompativel.")
    if timeline.get("status") not in {"ok", "stale"}:
        raise CaptureError("Timeline indisponivel no instante da captura.")
    if snapshot.get("session_id") != timeline.get("session_id") or sample.get("run_id") != timeline.get("run_id") or sample.get("sample_seq") != timeline.get("latest_sample_seq"):
        raise CaptureError("Snapshot e timeline pertencem a momentos ou sessoes diferentes.")
    events = timeline.get("events")
    if not isinstance(events, list) or len(events) > TIMELINE_LIMIT or any(not isinstance(event, dict) for event in events) or not isinstance(timeline.get("truncated"), bool):
        raise CaptureError("Janela de eventos invalida.")
    retained = timeline.get("retained_event_count")
    dropped = timeline.get("dropped_event_count")
    if not isinstance(retained, int) or retained < len(events) or retained > 120 or not isinstance(dropped, int) or dropped < 0:
        raise CaptureError("Contadores de retencao invalidos.")
    if timeline["truncated"] != (retained > len(events) or dropped > 0):
        raise CaptureError("Sinal de truncamento incoerente.")
    if not isinstance(payload.get("captured_utc"), str) or not payload["captured_utc"].endswith("Z"):
        raise CaptureError("Horario de captura invalido.")
    if payload.get("timeline_limit") != TIMELINE_LIMIT:
        raise CaptureError("Limite da timeline incompativel.")


def load_capture(path: Path) -> dict[str, Any]:
    if path.stat().st_size > MAX_CAPTURE_BYTES:
        raise CaptureError("Arquivo de captura excede 1 MiB.")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise CaptureError("A captura nao e um objeto JSON.")
    expected = data.pop("sha256", None)
    if not isinstance(expected, str) or len(expected) != 64 or hashlib.sha256(_canonical(data)).hexdigest() != expected:
        raise CaptureError("Integridade da captura nao confere.")
    _check_payload(data)
    data["sha256"] = expected
    return data


def export_capture(project: Path, godot: Path) -> Path:
    server = GodotMCP(project, godot, allow_write=False, allow_run=False)
    for _ in range(5):
        timeline = server.call("godot_live_timeline", {"limit": TIMELINE_LIMIT})
        snapshot = server.call("godot_live_snapshot", {})
        payload = {
            "format": CAPTURE_FORMAT,
            "format_version": CAPTURE_VERSION,
            "captured_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "timeline_limit": TIMELINE_LIMIT,
            "snapshot": snapshot,
            "timeline": timeline,
        }
        try:
            _check_payload(payload)
        except CaptureError:
            time.sleep(0.1)
            continue
        digest = hashlib.sha256(_canonical(payload)).hexdigest()
        payload["sha256"] = digest
        encoded = json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False).encode("utf-8")
        if len(encoded) > MAX_CAPTURE_BYTES:
            raise CaptureError("A captura excede 1 MiB; nenhum arquivo foi gravado.")
        directory = server.project / ".godot" / "ai_mcp" / "captures"
        if not directory.resolve().is_relative_to(server.project):
            raise CaptureError("Pasta de capturas resolve fora do projeto.")
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"capture-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}.json"
        with path.open("xb") as stream:
            stream.write(encoded)
        load_capture(path)
        return path
    raise CaptureError("Nao foi possivel obter snapshot e timeline coerentes da mesma sessao.")


def summary(data: dict[str, Any]) -> dict[str, Any]:
    snapshot = data["snapshot"]
    sample = snapshot["sample"]
    timeline = data["timeline"]
    return {
        "format_version": data["format_version"],
        "captured_utc": data["captured_utc"],
        "session_id": snapshot["session_id"],
        "run_id": sample["run_id"],
        "sample_seq": sample["sample_seq"],
        "scene_path": sample["scene_path"],
        "backend": sample["backend"],
        "status_at_capture": snapshot["status"],
        "age_ms_at_capture": snapshot["age_ms"],
        "events_exported": len(timeline["events"]),
        "events_before_window": timeline["truncated"],
        "events_retained_in_editor": timeline["retained_event_count"],
        "events_dropped_in_editor": timeline["dropped_event_count"],
        "sequence_gaps": snapshot["sequence_gaps"],
        "sha256": data["sha256"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="Capturar a sessao ativa do editor")
    export.add_argument("--project", type=Path, required=True)
    export.add_argument("--godot", type=Path, required=True)
    inspect = commands.add_parser("inspect", help="Reabrir e validar uma captura local")
    inspect.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "export":
            path = export_capture(args.project, args.godot)
            data = load_capture(path)
            print(json.dumps({"capture_file": str(path), **summary(data)}, ensure_ascii=False, indent=2))
        else:
            data = load_capture(args.path)
            print(json.dumps(summary(data), ensure_ascii=False, indent=2))
    except (CaptureError, OSError, json.JSONDecodeError, ToolError, ValueError) as exc:
        parser.exit(2, f"Captura indisponivel: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
