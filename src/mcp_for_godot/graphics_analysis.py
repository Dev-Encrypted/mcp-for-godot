"""Diagnósticos explicáveis sobre dados públicos, sem atribuir causalidade a agregados."""
from __future__ import annotations

import math


def report(snapshot: dict) -> dict:
    if snapshot.get("status") != "ok":
        return {"status": "unavailable", "error": snapshot.get("error"), "snapshot_status": snapshot.get("status")}
    sample = snapshot["sample"]
    timing = sample.get("graphics_performance", {})
    hypotheses = []
    p50, p95 = timing.get("p50_ms"), timing.get("p95_ms")
    if isinstance(p50, (int, float)) and isinstance(p95, (int, float)) and p50 > 0 and p95 > p50 * 1.5:
        hypotheses.append({"code": "uneven_frame_intervals", "evidence": {"p50_ms": p50, "p95_ms": p95}, "next_test": "Repetir A/B com mesma cena, V-Sync e carga; separar script, coleta, render CPU e GPU.", "cause": "unknown"})
    for viewport in sample.get("viewports", []):
        calls = viewport.get("canvas_draw_calls", {})
        objects = viewport.get("canvas_objects", {})
        if calls.get("status") == objects.get("status") == "ok" and objects.get("value", 0) >= 32 and calls.get("value", 0) > objects["value"] * 0.75:
            hypotheses.append({"code": "inspect_batching", "viewport_path": viewport["path"], "evidence": {"objects": objects["value"], "draw_calls": calls["value"]}, "next_test": "Inspecionar texturas/materiais e ordem de desenho; testar uma alteração isolada e comparar imagem e tempos.", "cause": "unproven"})
    return {"status": "ok", "origin": "public_runtime_metrics", "run_id": sample["run_id"], "session_id": snapshot["session_id"], "scene_path": sample["scene_path"], "backend": sample["backend"], "sample_seq": sample["sample_seq"], "age_ms": snapshot["age_ms"], "observed": {"frame_intervals": timing, "viewports": sample.get("viewports", []), "performance": sample["performance"]}, "hypotheses": hypotheses, "capabilities": {"individual_draw_calls": "not_exposed", "internal_pass_timings": "not_exposed", "overdraw": "not_measured", "shader_stalls": "not_measured", "pixel_ownership": "not_measured", "gpu_timing": timing.get("gpu_status", "unavailable"), "other_hardware": "not_validated"}, "automatic_optimization": False}


def pick(context: dict, pixel: list[float]) -> dict:
    candidates = []
    for item in context.get("items", []):
        box = item.get("bounds")
        if item.get("visible_in_tree") and isinstance(box, list) and len(box) == 4:
            x, y, w, h = box
            if x <= pixel[0] < x + w and y <= pixel[1] < y + h:
                candidates.append(item)
    return {"pixel": pixel, "candidates": candidates, "relation": "axis_aligned_bounds_only", "pixel_ownership": "unproven", "occlusion_clipping_shader_displacement": "unobserved", "truncated": context.get("truncated", True)}


def compare(before: dict, after: dict) -> dict:
    mismatches = [key for key in ("scene_path", "backend", "viewport_path", "width", "height") if before.get(key) != after.get(key)]
    deltas = {}
    old = before.get("frame_context", {}).get("performance", {})
    new = after.get("frame_context", {}).get("performance", {})
    for key in ("p50_ms", "p95_ms", "max_ms", "gpu_ms", "render_cpu_ms"):
        a, b = old.get(key), new.get(key)
        if type(a) in (int, float) and type(b) in (int, float) and math.isfinite(a) and math.isfinite(b):
            deltas[key] = {"before": a, "after": b, "delta": b - a}
    return {"status": "incompatible" if mismatches else "comparable_with_limits", "before_capture_id": before["capture_id"], "after_capture_id": after["capture_id"], "mismatches": mismatches, "png_identical": before["sha256"] == after["sha256"], "timing_deltas": deltas, "performance_improvement": "unproven_requires_repeated_AB", "pixel_tolerance_comparison": "not_computed", "same_run": before.get("run_id") == after.get("run_id"), "limits": ["Identidade de cena não comprova conteúdo, câmera, carga ou aquecimento iguais.", "Intervalos do processo não são tempo GPU; janelas podem se sobrepor.", "Diferença de PNG pode ser animação esperada; não é regressão por si só."]}
