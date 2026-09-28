from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mcp_for_godot.file_transaction import FileTransactions, TransactionError  # noqa: E402
from mcp_for_godot.resource_transaction import ResourceTransactions, ResourceTransactionError  # noqa: E402
from mcp_for_godot.texture_import_transaction import TextureImportTransactions, TextureImportError  # noqa: E402


def digest(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def png(width: int = 2, height: int = 2) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"\x33\x88\xcc\xff" * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


class TransactionContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="mcp-for-godot-tx-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
        self.state = {"project_path": str(self.project), "open_scenes": [], "unsaved_scenes": [], "open_scripts": [], "playing": False}

    def test_script_preview_apply_and_rollback(self) -> None:
        script = self.project / "main.gd"
        script.write_text("extends Node\n", encoding="utf-8")
        tx = FileTransactions(self.project, Path(sys.executable), "test")
        tx._validate = lambda path, work: {"method": "stub"}
        preview = tx.preview("res://main.gd", digest(script.read_bytes()), "extends Node2D\n", self.state)
        applied = tx.apply(preview["preview_id"], lambda: self.state)
        self.assertEqual(script.read_text(encoding="utf-8"), "extends Node2D\n")
        restored = tx.rollback(applied["checkpoint_id"], applied["after_sha256"], lambda: self.state)
        self.assertTrue(restored["verified"])
        self.assertEqual(script.read_text(encoding="utf-8"), "extends Node\n")

    def test_script_conflict_preserves_external_edit(self) -> None:
        script = self.project / "main.gd"
        script.write_text("extends Node\n", encoding="utf-8")
        tx = FileTransactions(self.project, Path(sys.executable), "test")
        tx._validate = lambda path, work: {"method": "stub"}
        preview = tx.preview("res://main.gd", digest(script.read_bytes()), "extends Node2D\n", self.state)
        applied = tx.apply(preview["preview_id"], lambda: self.state)
        script.write_text("extends Control\n", encoding="utf-8")
        with self.assertRaises(TransactionError) as caught:
            tx.rollback(applied["checkpoint_id"], applied["after_sha256"], lambda: self.state)
        self.assertEqual(caught.exception.code, "hash_conflict")
        self.assertEqual(script.read_text(encoding="utf-8"), "extends Control\n")

    def test_path_traversal_is_rejected(self) -> None:
        tx = FileTransactions(self.project, Path(sys.executable), "test")
        with self.assertRaises(TransactionError) as caught:
            tx.preview("res://../outside.gd", None, "extends Node\n", self.state)
        self.assertEqual(caught.exception.code, "invalid_path")

    def test_uid_repair_apply_and_rollback(self) -> None:
        (self.project / "scenes").mkdir()
        (self.project / "resources").mkdir()
        resource = self.project / "resources" / "block.tres"
        resource.write_text('[gd_resource type="Resource" format=3 uid="uid://correct123"]\n', encoding="utf-8")
        scene = self.project / "scenes" / "main.tscn"
        before = b'[gd_scene format=3 uid="uid://scene123"]\n[ext_resource type="Resource" uid="uid://wrong123" path="res://resources/block.tres" id="1"]\n[node name="Root" type="Node"]\n'
        scene.write_bytes(before)
        tx = ResourceTransactions(self.project, "test")
        preview = tx.preview_uid("res://scenes/main.tscn", "res://resources/block.tres", digest(scene.read_bytes()), digest(resource.read_bytes()), self.state)
        applied = tx.apply_uid(preview["preview_id"], lambda: self.state)
        self.assertIn("uid://correct123", scene.read_text(encoding="utf-8"))
        tx.rollback_uid(applied["checkpoint_id"], applied["after_sha256"], lambda: self.state)
        self.assertEqual(scene.read_bytes(), before)

    def test_uid_repair_refuses_open_scene(self) -> None:
        (self.project / "scenes").mkdir()
        (self.project / "resources").mkdir()
        resource = self.project / "resources" / "block.tres"
        resource.write_text('[gd_resource type="Resource" format=3 uid="uid://correct123"]\n', encoding="utf-8")
        scene = self.project / "scenes" / "main.tscn"
        scene.write_text('[gd_scene format=3]\n[ext_resource type="Resource" uid="uid://wrong123" path="res://resources/block.tres" id="1"]\n', encoding="utf-8")
        tx = ResourceTransactions(self.project, "test")
        with self.assertRaises(ResourceTransactionError) as caught:
            tx.preview_uid("res://scenes/main.tscn", "res://resources/block.tres", digest(scene.read_bytes()), digest(resource.read_bytes()), {**self.state, "open_scenes": ["res://scenes/main.tscn"]})
        self.assertEqual(caught.exception.code, "scene_open")

    def test_texture_preview_validates_png_and_hash(self) -> None:
        image = self.project / "image.png"
        image.write_bytes(png())
        tx = TextureImportTransactions(self.project, "test")
        candidate = '[remap]\nimporter="texture"\n\n[params]\nmipmaps/generate=true\n'
        preview = tx.preview("res://image.png", digest(image.read_bytes()), None, {"mipmaps/generate": True}, lambda _: {"status": "ok", "candidate_text": candidate}, self.state)
        self.assertEqual(preview["dimensions"], [2, 2])
        image.write_bytes(png(3, 2))
        with self.assertRaises(TextureImportError) as caught:
            tx.apply(preview["preview_id"], lambda: self.state, lambda _: {})
        self.assertEqual(caught.exception.code, "hash_conflict")


if __name__ == "__main__":
    unittest.main()
