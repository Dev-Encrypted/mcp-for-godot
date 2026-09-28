"""Servidor MCP stdio para um unico projeto Godot aberto no editor local.

Implementa ferramentas MCP por stdio para inicializacao legada 2025-11-25 e
pedidos modernos 2026-07-28 usando apenas a biblioteca padrao. Nunca escreve
mensagens de diagnostico em stdout.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import math
from collections import deque
from .graphics_analysis import report as graphics_report, pick as graphics_pick, compare as graphics_compare
from .file_transaction import FileTransactions, TransactionError, _ProjectLock
from .resource_transaction import ResourceTransactions, ResourceTransactionError
from .texture_import_transaction import TextureImportTransactions, TextureImportError
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from typing import Any


PROTOCOL_VERSION = "2025-11-25"
MODERN_PROTOCOL_VERSION = "2026-07-28"
SERVER_VERSION = "0.10.0"
MAX_MCP_LINE = 1_048_576
MAX_BRIDGE_LINE = 1_048_576
IMAGE_POLL_SECONDS = 0.1
READABLE_SUFFIXES = {".gd", ".gdshader", ".tscn", ".tres", ".godot", ".md", ".json", ".cfg"}
LISTABLE_SUFFIXES = READABLE_SUFFIXES | {".png", ".jpg", ".jpeg", ".svg", ".ogg", ".wav"}
SKIP_DIRS = {".godot", ".git", "node_modules", "__pycache__"}


class ToolError(Exception):
    """Erro de ferramenta exibido ao agente como isError."""

    def __init__(self, message: str, code: str | None = None, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


def _object_schema(properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": required or [], "additionalProperties": False}


def _validate_schema(value: Any, schema: dict[str, Any], location: str = "arguments", depth: int = 0) -> None:
    if depth > 10:
        raise ToolError("Argumentos aninhados demais.", "invalid_argument")
    allowed = schema.get("type")
    if allowed is None:
        if type(value) in (int, float) and not math.isfinite(value):
            raise ToolError(f"{location} deve ser finito.", "invalid_argument")
        if isinstance(value, str):
            try:
                value.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise ToolError(f"{location} nao e UTF-8 valido.", "invalid_argument") from exc
        elif isinstance(value, list):
            if len(value) > 1024:
                raise ToolError(f"{location} excede limite de itens.", "invalid_argument")
            for index, item in enumerate(value):
                _validate_schema(item, {}, f"{location}[{index}]", depth + 1)
        elif isinstance(value, dict):
            if len(value) > 1024:
                raise ToolError(f"{location} excede limite de campos.", "invalid_argument")
            for key, item in value.items():
                if not isinstance(key, str):
                    raise ToolError(f"{location} tem chave invalida.", "invalid_argument")
                _validate_schema(key, {"type": "string"}, location, depth + 1)
                _validate_schema(item, {}, f"{location}.{key}", depth + 1)
        elif value is not None and type(value) not in (bool, int, float):
            raise ToolError(f"{location} tem tipo invalido.", "invalid_argument")
        return
    types = allowed if isinstance(allowed, list) else [allowed]
    matches = {
        "object": lambda: isinstance(value, dict),
        "array": lambda: isinstance(value, list),
        "string": lambda: isinstance(value, str),
        "integer": lambda: type(value) is int,
        "number": lambda: type(value) in (int, float) and math.isfinite(value),
        "boolean": lambda: type(value) is bool,
        "null": lambda: value is None,
    }
    if not any(kind in matches and matches[kind]() for kind in types):
        raise ToolError(f"{location} tem tipo invalido.", "invalid_argument")
    if "enum" in schema and value not in schema["enum"]:
        raise ToolError(f"{location} fora das opcoes permitidas.", "invalid_argument")
    if isinstance(value, str):
        try:
            value.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise ToolError(f"{location} nao e UTF-8 valido.", "invalid_argument") from exc
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", MAX_MCP_LINE):
            raise ToolError(f"{location} excede limite de caracteres.", "invalid_argument")
    elif type(value) in (int, float):
        if value < schema.get("minimum", -math.inf) or value > schema.get("maximum", math.inf):
            raise ToolError(f"{location} fora dos limites.", "invalid_argument")
    elif isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", 1024):
            raise ToolError(f"{location} excede limite de itens.", "invalid_argument")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(value):
                _validate_schema(item, item_schema, f"{location}[{index}]", depth + 1)
    elif isinstance(value, dict):
        if len(value) < schema.get("minProperties", 0) or len(value) > schema.get("maxProperties", 1024):
            raise ToolError(f"{location} excede limite de campos.", "invalid_argument")
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                raise ToolError(f"{location}.{key} obrigatorio.", "invalid_argument")
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if not isinstance(key, str):
                raise ToolError(f"{location} tem chave invalida.", "invalid_argument")
            try:
                key.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise ToolError(f"{location} tem chave UTF-8 invalida.", "invalid_argument") from exc
            item_schema = properties.get(key)
            if item_schema is None:
                if extra is False:
                    raise ToolError(f"{location}.{key} nao permitido.", "invalid_argument")
                item_schema = extra if isinstance(extra, dict) else None
            if isinstance(item_schema, dict):
                _validate_schema(item, item_schema, f"{location}.{key}", depth + 1)


STRING = {"type": "string"}
VECTOR = {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}
NODE_TYPES = ["Node2D", "Control", "ColorRect", "Label", "Button", "Sprite2D", "Camera2D", "CharacterBody2D", "StaticBody2D", "RigidBody2D", "Area2D", "CollisionShape2D", "CollisionPolygon2D", "AnimatedSprite2D", "TileMapLayer", "AudioStreamPlayer2D", "Marker2D", "Path2D", "PathFollow2D", "Timer", "CanvasLayer", "Panel", "TextureRect", "HBoxContainer", "VBoxContainer", "GridContainer", "MarginContainer", "Node3D", "Sprite3D", "Camera3D", "MeshInstance3D", "DirectionalLight3D", "OmniLight3D"]

TOOLS = [
    {"name": "godot_texture_import_preview", "description": "Previa ConfigFile de importacao PNG sem carregar recurso; exige --allow-write, hashes do PNG e sidecar e opcoes restritas.", "inputSchema": _object_schema({"path": STRING, "expected_source_sha256": STRING, "expected_import_sha256": {"type": ["string", "null"]}, "options": {"type": "object", "properties": {"compress/mode": {"type": "integer", "enum": [0, 1]}, "mipmaps/generate": {"type": "boolean"}, "process/fix_alpha_border": {"type": "boolean"}, "process/size_limit": {"type": "integer", "enum": [0, 256, 512, 1024, 2048]}}, "additionalProperties": False, "minProperties": 1}}, ["path", "expected_source_sha256", "expected_import_sha256", "options"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_texture_import_apply", "description": "Aplica previa PNG com checkpoint persistente e EditorFileSystem.reimport_files; pode executar plugins de importacao. Exige --allow-write e --allow-run.", "inputSchema": _object_schema({"preview_id": STRING}, ["preview_id"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_texture_import_rollback", "description": "Compensa opcoes do sidecar e reimporta cache sob hash e checkpoint; nao restaura cache byte a byte. Exige --allow-write e --allow-run.", "inputSchema": _object_schema({"checkpoint_id": STRING, "expected_current_sha256": {"type": ["string", "null"]}}, ["checkpoint_id", "expected_current_sha256"]), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_uid_repair_preview", "description": "Prévia textual de correção do UID de um recurso em uma cena .tscn fechada, com hashes de cena e recurso; consumidores dinâmicos não são observados.", "inputSchema": _object_schema({"scene_path": STRING, "resource_path": STRING, "expected_scene_sha256": STRING, "expected_resource_sha256": STRING}, ["scene_path", "resource_path", "expected_scene_sha256", "expected_resource_sha256"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_uid_repair_apply", "description": "Aplica prévia de UID em uma cena fechada, com lock/checkpoint/hash e troca atômica. Exige --allow-write.", "inputSchema": _object_schema({"preview_id": STRING}, ["preview_id"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_uid_repair_rollback", "description": "Restaura cena do checkpoint se hashes da cena e recurso ainda coincidirem. Exige --allow-write.", "inputSchema": _object_schema({"checkpoint_id": STRING, "expected_current_sha256": STRING}, ["checkpoint_id", "expected_current_sha256"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_mesh_library_preview", "description": "Inspeciona textualmente uma cena 3D fechada para candidatos MeshInstance3D diretos; não carrega cena.", "inputSchema": _object_schema({"scene_path": STRING, "output_path": STRING, "expected_scene_sha256": STRING}, ["scene_path", "output_path", "expected_scene_sha256"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_mesh_library_export", "description": "Carrega cena 3D permitida, gera MeshLibrary em estágio e promove arquivo com hash/checkpoint. Carregar cena pode executar código; exige --allow-write, --allow-run e allow_scene_load=true.", "inputSchema": _object_schema({"scene_path": STRING, "output_path": STRING, "expected_scene_sha256": STRING, "allow_scene_load": {"type": "boolean"}}, ["scene_path", "output_path", "expected_scene_sha256", "allow_scene_load"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_mesh_library_rollback", "description": "Remove MeshLibrary criada somente se hash coincidir e nenhum consumidor em disco for encontrado. Exige --allow-write.", "inputSchema": _object_schema({"checkpoint_id": STRING, "expected_current_sha256": STRING}, ["checkpoint_id", "expected_current_sha256"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_gameplay_attach_script_checked", "description": "Previsualiza ou associa script .gd existente a no sem script com SHA, revisao e UndoRedo. A aplicacao carrega codigo executavel; exige --allow-write, --allow-run e --allow-script-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "node_path": STRING, "script_path": STRING, "script_sha256": {"type": "string", "minLength": 64, "maxLength": 64}, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "node_path", "script_path", "script_sha256"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_debugger_events", "description": "Le erros e saida do depurador nativo do Play no editor com cursor e identidade de sessao/geracao. Nao confunde geracao nativa com run_id da amostra grafica.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}, "run_generation": {"type": "integer", "minimum": 0}, "after_cursor": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 40}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_gameplay_compose_checked", "description": "Previsualiza ou compoe ate 24 nos tipados 2D/3D em uma acao de historico da cena, com revisao e recursos restritos. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "parent_path": STRING, "nodes": {"type": "array", "minItems": 1, "maxItems": 24, "items": {"type": "object", "properties": {"id": STRING, "parent": STRING, "type": STRING, "name": STRING, "properties": {"type": "object", "maxProperties": 8}, "resource": {"type": "object"}}, "required": ["id", "type", "name"], "additionalProperties": False}}, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "nodes"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_tilemap_compose_checked", "description": "Compoe TileMapLayer 2D com atlas e colisoes restritas, revisao de cena, hash de textura e UndoRedo. Previa nao usa ResourceLoader; exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": STRING, "parent_path": STRING, "name": STRING, "texture_path": STRING, "texture_sha256": STRING, "tile_size": {"type": "array", "items": {"type": "integer", "minimum": 8, "maximum": 64}, "minItems": 2, "maxItems": 2}, "atlas_tiles": {"type": "array", "items": {"type": "object", "properties": {"atlas": {"type": "array", "items": {"type": "integer", "minimum": 0, "maximum": 63}, "minItems": 2, "maxItems": 2}, "solid": {"type": "boolean"}}, "required": ["atlas", "solid"], "additionalProperties": False}, "minItems": 1, "maxItems": 16}, "cells": {"type": "array", "items": {"type": "object", "properties": {"cell": {"type": "array", "items": {"type": "integer", "minimum": -64, "maximum": 64}, "minItems": 2, "maxItems": 2}, "atlas": {"type": "array", "items": {"type": "integer", "minimum": 0, "maximum": 63}, "minItems": 2, "maxItems": 2}}, "required": ["cell", "atlas"], "additionalProperties": False}, "minItems": 1, "maxItems": 256}, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "parent_path", "name", "texture_path", "texture_sha256", "tile_size", "atlas_tiles", "cells"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_script_preview", "description": "Previsualiza troca de um .gd com SHA esperado e diff. Recusa @tool, inicializacao estatica e dependencias carregadas no parse. Exige --allow-write e --allow-script-write.", "inputSchema": _object_schema({"path": STRING, "expected_sha256": {"type": ["string", "null"]}, "content": STRING}, ["path", "expected_sha256", "content"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_script_apply", "description": "Valida script em projeto minimo descartavel, grava checkpoint e troca atomicamente apos revalidar SHA/editor. Exige --allow-write, --allow-run e --allow-script-write.", "inputSchema": _object_schema({"preview_id": STRING}, ["preview_id"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_script_rollback", "description": "Restaura checkpoint persistido somente se SHA atual coincidir; verifica conteudo restaurado. Exige --allow-write e --allow-script-write.", "inputSchema": _object_schema({"checkpoint_id": STRING, "expected_current_sha256": STRING}, ["checkpoint_id", "expected_current_sha256"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_checkpoint_list", "description": "Lista checkpoints persistidos do projeto, com estado por hash e sem conteudo. Exige --allow-write.", "inputSchema": _object_schema({"limit": {"type": "integer", "minimum": 1, "maximum": 128}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_open_scene_checked", "description": "Abre cena .tscn com cena ativa esperada e SHA alvo opcional; carregar pode executar @tool. Exige --allow-write e --allow-run.", "inputSchema": _object_schema({"expected_active_scene_path": {"type": ["string", "null"]}, "path": STRING, "expected_target_sha256": STRING, "dry_run": {"type": "boolean"}}, ["expected_active_scene_path", "path"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_save_scene_checked", "description": "Salva cena com caminho, revisao de grafo e SHA do arquivo esperados. Exige --allow-write; nao fornece rollback do disco.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": STRING, "expected_disk_sha256": STRING, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "expected_disk_sha256"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_remove_leaf_checked", "description": "Remove no folha da cena esperada com revisao do grafo e historico do editor. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": STRING, "node_path": STRING, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "node_path"]), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_history_state", "description": "Le identidade, indice e nome da acao no historico da cena ativa.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_history_action_checked", "description": "Executa undo/redo somente com cena, revisao, historico, indice e nome exatos. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": STRING, "direction": {"type": "string", "enum": ["undo", "redo"]}, "expected_history_id": {"type": "integer", "minimum": 0}, "expected_action_index": {"type": "integer", "minimum": 0}, "expected_action_name": STRING}, ["expected_scene_path", "expected_graph_revision", "direction", "expected_history_id", "expected_action_index", "expected_action_name"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_graphics_inspect", "description": "Inspeciona propriedades graficas e recursos carregados de um CanvasItem da cena editada, com revisao para controle protegido.", "inputSchema": _object_schema({"node_path": STRING}, ["node_path"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_graphics_asset", "description": "Le hash e metadados de importacao de textura PNG/JPEG/WebP; valida fonte .gdshader pelo parser nativo, sem compilar pipeline GPU ou alterar importacao.", "inputSchema": _object_schema({"path": STRING}, ["path"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_graphics_edit_checked", "description": "Previsualiza/aplica alteracoes de CanvasItem, textura, shader e parametros; exige revisao, hashes dos recursos novos, --allow-write e suporta Desfazer/Refazer. Duplica material para preservar consumidores.", "inputSchema": _object_schema({"node_path": STRING, "expected_scene_path": STRING, "expected_revision": STRING, "changes": {"type": "object", "minProperties": 1, "maxProperties": 8, "additionalProperties": False, "properties": {"visible": {"type": "boolean"}, "modulate": STRING, "z_index": {"type": "integer", "minimum": -4096, "maximum": 4096}, "texture_filter": {"type": "integer", "minimum": 0, "maximum": 6}, "texture_repeat": {"type": "integer", "minimum": 0, "maximum": 3}, "texture_path": STRING, "shader_path": STRING, "shader_parameters": {"type": "object", "maxProperties": 16}}}, "expected_assets": {"type": "object", "additionalProperties": STRING}, "dry_run": {"type": "boolean"}}, ["node_path", "expected_scene_path", "expected_revision", "changes"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_graphics_report", "description": "Relata tempos e contadores observados, capacidades ausentes e hipoteses de batching/variacao de frames. Nao afirma causa nem aplica otimizacao.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_graphics_compare", "description": "Compara metadados das duas ultimas capturas deste cliente: identidade, hash PNG e tempos. Exige --allow-capture; diferenca nao prova regressao nem ganho de desempenho.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_status", "description": "Confere a conexao ao editor e informa a cena ativa do projeto configurado.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_version", "description": "Le a versao do binario Godot configurado, com timeout; nao inicia o editor.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_project_info", "description": "Resume configuracao e hash do project.godot fixado nesta instancia MCP.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_capabilities", "description": "Declara capacidades e permissoes efetivas desta instancia, separando ponte ativa, APIs publicas e extensoes do fork.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_editor_launch", "description": "Conecta ao editor existente ou inicia um editor do projeto fixado e o gerencia nesta instancia. Exige --allow-run.", "inputSchema": _object_schema({"headless": {"type": "boolean"}}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_editor_close", "description": "Encerra somente o editor iniciado por esta instancia MCP. Exige --allow-run.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_editor_log", "description": "Le buffer limitado da saida do editor iniciado nesta instancia, com cursor; indisponivel para editor externo.", "inputSchema": _object_schema({"after_cursor": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_run_project", "description": "Inicia somente o projeto configurado em processo Godot proprio, com backend permitido e log limitado. Exige --allow-run.", "inputSchema": _object_schema({"headless": {"type": "boolean"}, "rendering_method": {"type": "string", "enum": ["gl_compatibility", "forward_plus", "mobile"]}}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_stop_project", "description": "Encerra somente o processo de jogo iniciado por esta instancia MCP. Exige --allow-run.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_project_log", "description": "Le saida limitada com cursor do processo de jogo iniciado nesta instancia; inclui erros de script quando Godot os emite no stdout/stderr.", "inputSchema": _object_schema({"after_cursor": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_play_scene", "description": "Solicita Play no editor conectado para cena atual, principal ou caminho do projeto. Exige --allow-run; Stop pertence apenas a esta instancia MCP.", "inputSchema": _object_schema({"mode": {"type": "string", "enum": ["current", "main", "path"]}, "path": STRING}, ["mode"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_stop_scene", "description": "Para somente a execucao iniciada por esta instancia MCP. Exige --allow-run.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_input_action", "description": "Pressiona uma acao explicitamente autorizada em mcp_for_godot/allowed_input_actions por ate 1000 ms e aguarda liberacao no mesmo run_id. Exige --allow-run e --allow-input, Play proprio e coletor opt-in.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}, "run_id": STRING, "action": STRING, "duration_ms": {"type": "integer", "minimum": 1, "maximum": 1000}}, ["session_id", "run_id", "action", "duration_ms"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_create_scene", "description": "Cria uma cena nova em diretorio existente, sem sobrescrever; pre-visualizacao e compensacao com hash. Exige --allow-write.", "inputSchema": _object_schema({"path": STRING, "root_type": {"type": "string", "enum": ["Node2D", "Control", "Node3D"]}, "root_name": STRING, "dry_run": {"type": "boolean"}}, ["path", "root_type", "root_name"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_save_scene_as_checked", "description": "Salva a cena editada em caminho novo sem sobrescrever, com revisao do grafo, previa e compensacao protegida por hash. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "path": STRING, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "path"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_revert_created_scene", "description": "Remove somente cena criada nesta sessao do plugin, inalterada pelo hash e fora do editor/jogo. Exige --allow-write.", "inputSchema": _object_schema({"path": STRING, "expected_sha256": {"type": "string", "minLength": 64, "maxLength": 64}}, ["path", "expected_sha256"]), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_resource_uid", "description": "Consulta UID conhecido pelo cache ResourceUID do editor para recurso existente no projeto; nao altera arquivos.", "inputSchema": _object_schema({"path": STRING}, ["path"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_instance_scene_checked", "description": "Previa textual sem carregar subcena; aplicar instancia cena com hash/revisao e historico. Aplicacao pode executar @tool; exige --allow-write e --allow-run.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "source_path": STRING, "expected_source_sha256": STRING, "parent_path": STRING, "name": STRING, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "source_path", "expected_source_sha256", "parent_path", "name"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_close_scene_checked", "description": "Fecha apenas a cena ativa esperada e salva; recusa perder alteracoes pendentes. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING}, ["expected_scene_path"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_list_files", "description": "Lista recursos do projeto configurado, sem sair da raiz e sem incluir .godot.", "inputSchema": _object_schema({"limit": {"type": "integer", "minimum": 1, "maximum": 500}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_read_text", "description": "Le um arquivo de texto permitido do projeto (ate 128 KiB).", "inputSchema": _object_schema({"path": STRING}, ["path"]), "annotations": {"readOnlyHint": True}},
    {"name": "godot_scene_tree", "description": "Inspeciona os nos pertencentes a cena ativa no editor e propriedades selecionadas.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_dependency_graph", "description": "Mapeia nos da cena editada, scripts, sinais persistentes e dependencias declaradas de recursos; informa origem, ausencias e truncamento.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_live_snapshot", "description": "Le a ultima amostra de runtime publicada pelo depurador do editor; informa indisponibilidade e idade sem consultar o renderer sob demanda.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_live_timeline", "description": "Le eventos limitados do receptor do editor: amostras, mudancas observadas entre leituras, lacunas, backpressure e rejeicoes. Nao afirma causalidade nem inspeciona cada frame.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 40}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_live_image", "description": "Captura sob demanda um viewport selecionado (raiz por padrao) do jogo conectado ao depurador, em PNG limitado. Exige --allow-capture; pode incluir conteudo privado da janela.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}, "viewport_path": STRING, "pixel": VECTOR}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_live_evidence", "description": "Reune imagem, amostras antes/depois, eventos, metricas e resumo do grafo editado na mesma execucao; declara lacunas de frame e erro. Exige --allow-capture.", "inputSchema": _object_schema({"session_id": {"type": "integer", "minimum": 0}, "viewport_path": STRING, "timeline_limit": {"type": "integer", "minimum": 1, "maximum": 20}, "node_paths": {"type": "array", "items": STRING, "maxItems": 20}}), "annotations": {"readOnlyHint": True}},
    {"name": "godot_open_scene", "description": "Atalho legado para abrir cena sem precondicoes; bloqueado por padrao. Pode carregar @tool e alterar selecao; exige --allow-write, --allow-run e --allow-legacy-write.", "inputSchema": _object_schema({"path": STRING}, ["path"]), "annotations": {"readOnlyHint": False}},
    {"name": "godot_add_node", "description": "Adiciona um no de tipo permitido a cena ativa, usando o historico Desfazer/Refazer do editor. Exige --allow-write.", "inputSchema": _object_schema({"parent_path": STRING, "node_type": {"type": "string", "enum": NODE_TYPES}, "name": STRING}, ["parent_path", "node_type", "name"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_add_node_checked", "description": "Previsualiza ou cria um no permitido com ate oito propriedades tipadas somente se cena e revisao do grafo coincidirem; Desfazer/Refazer. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "parent_path": STRING, "node_type": {"type": "string", "enum": NODE_TYPES}, "name": STRING, "properties": {"type": "object", "maxProperties": 8}, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "parent_path", "node_type", "name"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_connect_signal_checked", "description": "Previsualiza ou conecta sinal persistente de dois nos da cena editada a metodo _on_ de script, com revisao do grafo e Desfazer/Refazer. Exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_graph_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "source_path": STRING, "signal": STRING, "target_path": STRING, "method": STRING, "dry_run": {"type": "boolean"}}, ["expected_scene_path", "expected_graph_revision", "source_path", "signal", "target_path", "method"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_set_property", "description": "Altera uma propriedade permitida com Desfazer/Refazer. Vetores: [x,y]; cores: #RRGGBB ou #RRGGBBAA. Exige --allow-write.", "inputSchema": _object_schema({"node_path": STRING, "property": {"type": "string", "enum": ["position", "size", "scale", "rotation_degrees", "visible", "modulate", "text", "color"]}, "value": {}}, ["node_path", "property", "value"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_set_property_checked", "description": "Altera uma propriedade da cena editada apenas se cena, revisao de godot_scene_tree e valor atual ainda coincidirem; usa Desfazer/Refazer e exige --allow-write.", "inputSchema": _object_schema({"expected_scene_path": STRING, "expected_revision": {"type": "string", "minLength": 64, "maxLength": 64}, "node_path": STRING, "property": {"type": "string", "enum": ["position", "size", "scale", "rotation_degrees", "visible", "modulate", "text", "color"]}, "expected_value": {}, "value": {}}, ["expected_scene_path", "expected_revision", "node_path", "property", "expected_value", "value"]), "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "godot_remove_leaf", "description": "Remove apenas um no folha pertencente a cena ativa, com Desfazer/Refazer. Exige --allow-write.", "inputSchema": _object_schema({"node_path": STRING}, ["node_path"]), "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "godot_undo", "description": "Desfaz apenas se a ultima acao da cena ativa tiver sido criada pelo MCP. Exige --allow-write.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_redo", "description": "Refaz apenas se a proxima acao da cena ativa tiver sido criada pelo MCP. Exige --allow-write.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_save_scene", "description": "Salva a cena ativa .tscn pelo editor. Exige --allow-write.", "inputSchema": _object_schema({}), "annotations": {"readOnlyHint": False}},
    {"name": "godot_validate", "description": "Executa a Godot 4.7.2 headless: import/editor, runtime (30 quadros) ou script SceneTree em tests/. Retorna saida, erros e codigo. Exige --allow-run.", "inputSchema": _object_schema({"mode": {"type": "string", "enum": ["import", "run", "test"]}, "test_path": STRING}, ["mode"]), "annotations": {"readOnlyHint": False}},
]

BRIDGE_OPS = {
    "godot_tilemap_compose_checked": "tilemap_compose_checked",
    "godot_open_scene_checked": "open_scene_checked",
    "godot_save_scene_checked": "save_scene_checked",
    "godot_remove_leaf_checked": "remove_leaf_checked",
    "godot_history_state": "history_state",
    "godot_history_action_checked": "history_action_checked",
    "godot_mesh_library_preview": "mesh_library_preview",
    "godot_gameplay_attach_script_checked": "gameplay_attach_script_checked",
    "godot_debugger_events": "debugger_events",
    "godot_gameplay_compose_checked": "gameplay_compose_checked",
    "godot_graphics_inspect": "graphics_inspect",
    "godot_graphics_asset": "graphics_asset",
    "godot_graphics_edit_checked": "graphics_edit_checked",
    "godot_status": "status",
    "godot_create_scene": "create_scene",
    "godot_save_scene_as_checked": "save_scene_as_checked",
    "godot_revert_created_scene": "revert_created_scene",
    "godot_resource_uid": "resource_uid",
    "godot_instance_scene_checked": "instance_scene_checked",
    "godot_close_scene_checked": "close_scene_checked",
    "godot_scene_tree": "scene_tree",
    "godot_dependency_graph": "dependency_graph",
    "godot_live_snapshot": "live_snapshot",
    "godot_live_timeline": "live_timeline",
    "godot_open_scene": "open_scene",
    "godot_add_node": "add_node",
    "godot_add_node_checked": "add_node_checked",
    "godot_connect_signal_checked": "connect_signal_checked",
    "godot_set_property": "set_property",
    "godot_set_property_checked": "set_property_checked",
    "godot_remove_leaf": "remove_leaf",
    "godot_undo": "undo",
    "godot_redo": "redo",
    "godot_save_scene": "save_scene",
}
WRITE_TOOLS = {"godot_uid_repair_apply", "godot_uid_repair_rollback", "godot_mesh_library_export", "godot_mesh_library_rollback", "godot_gameplay_attach_script_checked", "godot_gameplay_compose_checked", "godot_script_preview", "godot_script_apply", "godot_script_rollback", "godot_graphics_edit_checked", "godot_create_scene", "godot_save_scene_as_checked", "godot_revert_created_scene", "godot_instance_scene_checked", "godot_close_scene_checked", "godot_open_scene", "godot_add_node", "godot_add_node_checked", "godot_connect_signal_checked", "godot_set_property", "godot_set_property_checked", "godot_remove_leaf", "godot_undo", "godot_redo", "godot_save_scene"}
RUN_TOOLS = {"godot_validate", "godot_play_scene", "godot_stop_scene", "godot_editor_launch", "godot_editor_close", "godot_run_project", "godot_stop_project"}
LEGACY_WRITE_TOOLS = {"godot_open_scene", "godot_add_node", "godot_set_property", "godot_remove_leaf", "godot_undo", "godot_redo", "godot_save_scene"}
WRITE_TOOLS.add("godot_checkpoint_list")
WRITE_TOOLS.update({"godot_open_scene_checked", "godot_save_scene_checked", "godot_remove_leaf_checked", "godot_history_action_checked"})
WRITE_TOOLS.add("godot_tilemap_compose_checked")
WRITE_TOOLS.update({"godot_texture_import_preview", "godot_texture_import_apply", "godot_texture_import_rollback"})
RUN_TOOLS.update({"godot_texture_import_apply", "godot_texture_import_rollback"})
RUN_TOOLS.add("godot_open_scene")
for _tool in TOOLS:
    _tool["annotations"].setdefault("openWorldHint", False)
    if _tool["name"] == "godot_open_scene_checked":
        _tool["description"] = "Previa textual da abertura de cena com alvo e estado esperados exige --allow-write; aplicar carrega a cena e exige tambem --allow-run."
    elif _tool["name"] == "godot_instance_scene_checked":
        _tool["description"] = "Previa textual de subcena com SHA e revisao exige --allow-write; aplicar carrega/instancia recursos e exige tambem --allow-run."
    elif _tool["name"] == "godot_gameplay_attach_script_checked":
        _tool["description"] = "Previa de associacao de script exige --allow-write e --allow-script-write; aplicar carrega codigo e exige tambem --allow-run."
    elif _tool["name"] == "godot_tilemap_compose_checked":
        _tool["description"] = "Previa de TileMap 2D exige --allow-write e nao carrega recurso; aplicar carrega textura e exige tambem --allow-run."
    if _tool["name"] in {"godot_script_rollback", "godot_uid_repair_rollback", "godot_mesh_library_rollback", "godot_revert_created_scene", "godot_remove_leaf", "godot_remove_leaf_checked", "godot_save_scene", "godot_save_scene_checked", "godot_stop_scene", "godot_stop_project", "godot_editor_close"}:
        _tool["annotations"]["destructiveHint"] = True
    if _tool["name"] in LEGACY_WRITE_TOOLS and _tool["name"] != "godot_open_scene":
        _tool["description"] = "LEGADO sem precondicoes, bloqueado por padrao. " + _tool["description"] + " Exige --allow-legacy-write."


def _visible_tools(server: "GodotMCP") -> list[dict[str, Any]]:
    result = []
    for tool in TOOLS:
        name = tool["name"]
        if name in WRITE_TOOLS and not server.allow_write:
            continue
        if name in RUN_TOOLS and not server.allow_run:
            continue
        if name in LEGACY_WRITE_TOOLS and not server.allow_legacy_write:
            continue
        if name in {"godot_script_preview", "godot_script_apply", "godot_script_rollback", "godot_gameplay_attach_script_checked"} and not server.allow_script_write:
            continue
        if name in {"godot_script_apply", "godot_mesh_library_export"} and not server.allow_run:
            continue
        if name in {"godot_live_image", "godot_live_evidence", "godot_graphics_compare"} and not server.allow_capture:
            continue
        if name == "godot_input_action" and not (server.allow_run and server.allow_input):
            continue
        result.append(tool)
    return result


class GodotMCP:
    def __init__(self, project: Path, godot: Path, allow_write: bool, allow_run: bool, allow_capture: bool = False, allow_input: bool = False, allow_script_write: bool = False, allow_legacy_write: bool = False):
        self.project = project.resolve(strict=True)
        project_config = self.project / "project.godot"
        if not project_config.is_file() or project_config.is_symlink() or getattr(project_config, "is_junction", lambda: False)():
            raise ValueError(f"Nao ha project.godot em {self.project}")
        self.godot = godot.resolve(strict=True)
        if not self.godot.is_file():
            raise ValueError(f"Executavel Godot invalido: {self.godot}")
        self.allow_write = allow_write
        self.allow_run = allow_run
        self.allow_capture = allow_capture
        self.allow_input = allow_input
        self.allow_script_write = allow_script_write
        self.allow_legacy_write = allow_legacy_write
        self.legacy_initialized = False
        self.client_name = "local_stdio"
        self.current_trace_id: str | None = None
        self.graphics_captures = deque(maxlen=2)
        self.owner = uuid.uuid4().hex
        self.file_transactions = FileTransactions(self.project, self.godot, self.owner)
        self.resource_transactions = ResourceTransactions(self.project, self.owner)
        self.texture_transactions = TextureImportTransactions(self.project, self.owner)
        self.play_token: str | None = None
        self.editor_process: subprocess.Popen[bytes] | None = None
        self.editor_logs: deque[dict[str, Any]] = deque(maxlen=500)
        self.editor_log_seq = 0
        self.editor_log_lock = threading.Lock()
        self.game_process: subprocess.Popen[bytes] | None = None
        self.game_logs: deque[dict[str, Any]] = deque(maxlen=500)
        self.game_log_seq = 0
        self.game_log_lock = threading.Lock()
        self.game_run_id: str | None = None

    def _audit(self, request_id: Any, tool_name: str, args: dict[str, Any], result_code: str) -> bool:
        """Registro resumido e limitado; nenhuma entrada inclui codigo, token ou resposta."""
        try:
            base = self.file_transactions._dir().parent
            log = base / "operations.jsonl"
            old = base / "operations.jsonl.1"
            lock = base / "operations.lock"
            if any(path.is_symlink() or getattr(path, "is_junction", lambda: False)() for path in (log, old, lock)):
                return False
            def scalar(value: Any, limit: int) -> str | None:
                if value is None:
                    return None
                if type(value) not in (str, int):
                    return "invalid"
                return str(value)[:limit]
            entry = {
                "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "trace_id": self.current_trace_id or uuid.uuid4().hex, "request_id_type": type(request_id).__name__[:32], "owner": self.owner,
                "client": self.client_name[:80], "tool": tool_name[:80],
                "target": {key: scalar(args[key], 256) for key in ("path", "scene_path", "source_path", "output_path", "node_path", "resource_path") if key in args},
                "preconditions": {key: scalar(args[key], 80) for key in ("expected_sha256", "expected_current_sha256", "expected_scene_sha256", "expected_resource_sha256", "expected_source_sha256", "expected_graph_revision", "expected_revision", "expected_disk_sha256", "expected_target_sha256") if key in args},
                "result_code": result_code[:80],
            }
            line = (json.dumps(entry, ensure_ascii=True, separators=(",", ":")) + "\n").encode("utf-8")
            if len(line) > 2048:
                return False
            held = _ProjectLock(lock, TransactionError, self.owner)
            try:
                if log.is_file() and log.stat().st_size + len(line) > 1_048_576:
                    os.replace(log, old)
                with log.open("ab") as stream:
                    stream.write(line)
                    stream.flush()
                    os.fsync(stream.fileno())
                return True
            finally:
                held.unlink()
        except (OSError, ValueError, TransactionError):
            return False

    def _project_file(self, raw_path: Any, suffixes: set[str]) -> Path:
        if not isinstance(raw_path, str) or not raw_path or "\\" in raw_path or "\x00" in raw_path:
            raise ToolError("Caminho relativo invalido; use barras /.")
        pieces = raw_path.split("/")
        if any(piece in {"", ".", ".."} or piece.startswith(".") for piece in pieces):
            raise ToolError("Caminho oculto ou com traversal nao permitido.")
        ancestor = self.project
        for piece in pieces:
            ancestor /= piece
            if ancestor.is_symlink() or getattr(ancestor, "is_junction", lambda: False)():
                raise ToolError("Link ou junction recusado.", "invalid_path")
        candidate = ancestor.resolve()
        if not candidate.is_relative_to(self.project) or candidate.suffix.lower() not in suffixes:
            raise ToolError("Arquivo fora do projeto ou extensao nao permitida.")
        if not candidate.is_file():
            raise ToolError("Arquivo inexistente.")
        return candidate

    def _new_scene_path(self, raw_path: Any) -> str:
        if not isinstance(raw_path, str):
            raise ToolError("Caminho de cena invalido.", "invalid_path")
        path = raw_path.removeprefix("res://")
        if not path or "\\" in path or "\x00" in path or ":" in path or Path(path).suffix.lower() != ".tscn":
            raise ToolError("Caminho de cena invalido.", "invalid_path")
        if any(piece in {"", ".", ".."} or piece.startswith(".") for piece in path.split("/")):
            raise ToolError("Caminho de cena invalido.", "invalid_path")
        ancestor = self.project
        for piece in path.split("/"):
            ancestor /= piece
            if ancestor.is_symlink() or getattr(ancestor, "is_junction", lambda: False)():
                raise ToolError("Link ou junction recusado.", "invalid_path")
        candidate = ancestor.resolve()
        if not candidate.is_relative_to(self.project) or not candidate.parent.is_dir():
            raise ToolError("Cena fora do projeto ou diretorio inexistente.", "invalid_path")
        return "res://" + path

    def _assert_scene_unreferenced(self, scene_path: str) -> None:
        uid = self._bridge("resource_uid", {"path": scene_path}).get("uid")
        relative = scene_path.removeprefix("res://")
        needles = [scene_path.encode("utf-8"), relative.encode("utf-8")]
        if isinstance(uid, str) and uid.startswith("uid://"):
            needles.append(uid.encode("utf-8"))
        checked = 0
        total_bytes = 0
        references = []
        for base, dirs, names in os.walk(self.project, followlinks=False):
            kept = []
            for directory in sorted(dirs):
                if directory in SKIP_DIRS or directory.startswith("."):
                    continue
                child = Path(base) / directory
                if child.is_symlink() or getattr(child, "is_junction", lambda: False)():
                    raise ToolError("Diretorio vinculado impede varredura de consumidores.", "dependency_scan_incomplete")
                kept.append(directory)
            dirs[:] = kept
            for filename in sorted(names):
                candidate = Path(base) / filename
                if candidate.suffix.lower() not in {".tscn", ".tres", ".gd", ".gdshader", ".godot"} or candidate.resolve() == (self.project / relative).resolve():
                    continue
                if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)() or not candidate.resolve().is_relative_to(self.project):
                    raise ToolError("Dependencia por symlink fora do projeto; compensacao recusada.", "dependency_scan_incomplete")
                checked += 1
                size = candidate.stat().st_size
                total_bytes += size
                if checked > 5000 or size > 1_048_576 or total_bytes > 67_108_864:
                    raise ToolError("Varredura de dependencias excedeu limite; compensacao recusada.", "dependency_scan_incomplete")
                if any(needle in candidate.read_bytes() for needle in needles):
                    references.append(candidate.relative_to(self.project).as_posix())
                    if len(references) >= 5:
                        break
            if len(references) >= 5:
                break
        if references:
            raise ToolError("A cena criada ja e referenciada; remocao recusada.", "resource_referenced", {"files": references})

    def _bridge(self, operation: str, args: dict[str, Any]) -> dict[str, Any]:
        bridge_file = self.project / ".godot" / "ai_mcp" / "bridge.json"
        for candidate in (self.project / ".godot", self.project / ".godot" / "ai_mcp", bridge_file):
            if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)():
                raise ToolError("Ponte usa link ou junction recusado.", "invalid_bridge")
        try:
            info = json.loads(bridge_file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ToolError("Ponte indisponivel. Abra o projeto no editor com o plugin habilitado.") from exc
        if not isinstance(info, dict) or not isinstance(info.get("project_path"), str):
            raise ToolError("Metadados da ponte invalidos.", "invalid_bridge")
        bridge_project = Path(info["project_path"]).resolve()
        if bridge_project != self.project or info.get("protocol") != 1:
            raise ToolError("A ponte pertence a outro projeto ou usa outro protocolo.")
        port = info.get("port")
        token = info.get("token")
        if not isinstance(port, int) or not 1 <= port <= 65535 or not isinstance(token, str) or len(token) != 64:
            raise ToolError("Metadados da ponte invalidos.")
        request_id = self.current_trace_id or uuid.uuid4().hex
        try:
            message = json.dumps({"id": request_id, "token": token, "op": operation, "args": args}, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
        except (TypeError, ValueError, UnicodeEncodeError) as exc:
            raise ToolError("Argumentos da ponte invalidos.", "invalid_argument") from exc
        if len(message) > 65536:
            raise ToolError("Requisicao maior que o limite da ponte (64 KiB).")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                connection.settimeout(45)
                connection.sendall(message)
                chunks = bytearray()
                while b"\n" not in chunks:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    chunks.extend(chunk)
                    if len(chunks) > MAX_BRIDGE_LINE:
                        raise ToolError("Resposta da ponte excedeu o limite.")
        except (OSError, TimeoutError) as exc:
            raise ToolError("Editor nao respondeu na porta local registrada. Confira se ainda esta aberto.") from exc
        try:
            reply = json.loads(bytes(chunks).split(b"\n", 1)[0])
        except (ValueError, IndexError) as exc:
            raise ToolError("Resposta da ponte invalida ou incompleta.") from exc
        if not isinstance(reply, dict) or reply.get("id") != request_id:
            raise ToolError("Identificador da resposta da ponte nao confere.")
        if not reply.get("ok"):
            raise ToolError(str(reply.get("error", "Operacao rejeitada pelo editor")), reply.get("error_code"), reply.get("error_details"))
        result = reply.get("result")
        if not isinstance(result, dict):
            raise ToolError("Resultado da ponte nao e um objeto.")
        if operation == "status" and (not isinstance(result.get("project_path"), str) or Path(result["project_path"]).resolve() != self.project):
            raise ToolError("O editor ativo abriu outro projeto.")
        if operation in {"live_snapshot", "live_timeline"} and result.get("status") not in {"ok", "stale", "unavailable"}:
            raise ToolError("Estado de observacao vivo invalido.")
        return result

    def call(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(args, dict):
            raise ToolError("arguments deve ser um objeto.", "invalid_argument")
        if name not in {tool["name"] for tool in TOOLS}:
            raise ToolError(f"Ferramenta desconhecida: {name}", "unknown_tool")
        if name in WRITE_TOOLS and not self.allow_write:
            raise ToolError("Edicao bloqueada. Inicie o servidor com --allow-write para este projeto.", "write_disabled")
        if name in RUN_TOOLS and not self.allow_run:
            raise ToolError("Execucao bloqueada. Inicie o servidor com --allow-run para este projeto.", "run_disabled")
        if name in LEGACY_WRITE_TOOLS and not self.allow_legacy_write:
            raise ToolError("Atalho legado sem precondicoes bloqueado; use ferramenta checked ou --allow-legacy-write.", "legacy_write_disabled")
        _validate_schema(args, next(tool["inputSchema"] for tool in TOOLS if tool["name"] == name))
        if name == "godot_instance_scene_checked" and args.get("dry_run", False) is not True and not self.allow_run:
            raise ToolError("Instanciar subcena exige --allow-run porque o carregamento pode executar codigo.", "run_disabled")
        if name == "godot_open_scene_checked" and args.get("dry_run", False) is not True and not self.allow_run:
            raise ToolError("Abrir cena exige --allow-run porque o carregamento pode executar codigo.", "run_disabled")
        if name == "godot_tilemap_compose_checked" and args.get("dry_run", False) is not True and not self.allow_run:
            raise ToolError("Compor TileMap carrega textura e exige --allow-run.", "run_disabled")
        if name == "godot_checkpoint_list":
            limit = args.get("limit", 64)
            try:
                return {"checkpoints": (self.file_transactions.list_checkpoints(limit) + self.resource_transactions.list_checkpoints(limit) + self.texture_transactions.list_checkpoints(limit))[:limit], "limit": limit}
            except (TransactionError, ResourceTransactionError, TextureImportError) as exc:
                raise ToolError(str(exc), exc.code, exc.details) from exc
        if name in {"godot_texture_import_preview", "godot_texture_import_apply", "godot_texture_import_rollback"}:
            def import_state() -> dict[str, Any]:
                return self._bridge("status", {})
            try:
                tx = self.texture_transactions
                if name == "godot_texture_import_preview":
                    return tx.preview(args["path"], args["expected_source_sha256"], args["expected_import_sha256"], args["options"], lambda value: self._bridge("texture_import_prepare", value), import_state())
                if name == "godot_texture_import_apply":
                    return tx.apply(args["preview_id"], import_state, lambda value: self._bridge("texture_reimport", value))
                return tx.rollback(args["checkpoint_id"], args["expected_current_sha256"], import_state, lambda value: self._bridge("texture_reimport", value), lambda value: self._bridge("texture_import_prepare", value))
            except TextureImportError as exc:
                raise ToolError(str(exc), exc.code, exc.details) from exc
        if name in {"godot_uid_repair_preview", "godot_uid_repair_apply", "godot_uid_repair_rollback", "godot_mesh_library_preview", "godot_mesh_library_export", "godot_mesh_library_rollback"}:
            def resource_state() -> dict[str, Any]:
                status = self._bridge("status", {})
                return {"project_path": status.get("project_path"), "open_scenes": status.get("open_scenes"), "unsaved_scenes": status.get("unsaved_scenes"), "active_scene_path": status.get("scene_path"), "playing": status.get("playing")}
            try:
                tx = self.resource_transactions
                if name == "godot_uid_repair_preview":
                    return tx.preview_uid(args.get("scene_path"), args.get("resource_path"), args.get("expected_scene_sha256"), args.get("expected_resource_sha256"), resource_state())
                if name == "godot_uid_repair_apply":
                    return tx.apply_uid(args.get("preview_id"), resource_state)
                if name == "godot_uid_repair_rollback":
                    return tx.rollback_uid(args.get("checkpoint_id"), args.get("expected_current_sha256"), resource_state)
                if name == "godot_mesh_library_rollback":
                    return tx.rollback_mesh_library(args.get("checkpoint_id"), args.get("expected_current_sha256"), resource_state)
                scene_name, _ = tx._path(args.get("scene_path"), {".tscn"})
                output_name, _ = tx._new_path(args.get("output_path"), ".tres")
                tx._state(scene_name, resource_state())
                expected = args.get("expected_scene_sha256")
                if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                    raise ToolError("expected_scene_sha256 invalido.", "invalid_hash")
                bridge_args = {"scene_path": scene_name, "output_path": output_name, "expected_scene_sha256": expected}
                if name == "godot_mesh_library_preview":
                    return self._bridge("mesh_library_preview", bridge_args)
                if not self.allow_run or args.get("allow_scene_load") is not True:
                    raise ToolError("Exportacao exige --allow-run e allow_scene_load=true.", "scene_load_disabled")
                tx.prepare_mesh_stage()
                generated = self._bridge("mesh_library_generate", dict(bridge_args, allow_scene_load=True))
                if generated.get("status") != "ok":
                    return generated
                try:
                    return tx.promote_mesh_library(generated.get("stage_id"), generated.get("staged_sha256"), scene_name, expected, output_name, resource_state)
                except (ResourceTransactionError, ToolError):
                    try:
                        self._bridge("mesh_library_discard", {"stage_id": generated.get("stage_id")})
                    except ToolError:
                        pass
                    raise
            except ResourceTransactionError as exc:
                raise ToolError(str(exc), exc.code, exc.details) from exc
        if name == "godot_gameplay_attach_script_checked":
            if not self.allow_script_write or (args.get("dry_run", False) is not True and not self.allow_run):
                raise ToolError("Associacao de script exige --allow-script-write; aplicacao exige --allow-run.", "script_execution_disabled")
        if name == "godot_gameplay_compose_checked" and args.get("dry_run", False) is not True:
            nodes = args.get("nodes", [])
            if any(isinstance(node, dict) and node.get("type") == "MCPForGodotRuntimeProbe" for node in nodes) and not self.allow_run:
                raise ToolError("Compor probe executavel exige --allow-run.", "run_disabled")
        if name in {"godot_script_preview", "godot_script_apply", "godot_script_rollback"}:
            if not self.allow_script_write:
                raise ToolError("Alteracao de codigo executavel bloqueada. Use --allow-script-write para este projeto.", "script_write_disabled")
            try:
                if name == "godot_script_preview":
                    if not isinstance(args.get("content"), str):
                        raise ToolError("content deve ser texto.", "invalid_content")
                    try:
                        args["content"].encode("utf-8")
                    except UnicodeEncodeError as exc:
                        raise ToolError("content nao e UTF-8 valido.", "invalid_encoding") from exc
                    return self.file_transactions.preview(args.get("path"), args.get("expected_sha256"), args.get("content"), self._bridge("status", {}))
                if name == "godot_script_apply":
                    if not self.allow_run:
                        raise ToolError("Validacao exige --allow-run.", "run_disabled")
                    return self.file_transactions.apply(args.get("preview_id"), lambda: self._bridge("status", {}))
                return self.file_transactions.rollback(args.get("checkpoint_id"), args.get("expected_current_sha256"), lambda: self._bridge("status", {}))
            except TransactionError as exc:
                raise ToolError(str(exc), exc.code, exc.details) from exc
        if name == "godot_input_action":
            if not self.allow_run or not self.allow_input:
                raise ToolError("Entrada bloqueada. Use --allow-run e --allow-input para este projeto.", "input_disabled")
            if self.play_token is None:
                raise ToolError("A entrada exige Play iniciado por esta instancia MCP.", "not_owner")
            session_id, run_id, action, duration_ms = (args.get(key) for key in ("session_id", "run_id", "action", "duration_ms"))
            if type(session_id) is not int or session_id < 0 or not isinstance(run_id, str) or not 1 <= len(run_id) <= 80 or not isinstance(action, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", action) or type(duration_ms) is not int or not 1 <= duration_ms <= 1000:
                raise ToolError("Argumentos de entrada invalidos.", "invalid_input")
            result = self._bridge("input_action_start", {"session_id": session_id, "run_id": run_id, "action": action, "duration_ms": duration_ms})
            if result.get("status") != "pending" or type(result.get("session_id")) is not int or not isinstance(result.get("command_id"), str):
                return result
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                time.sleep(0.05)
                outcome = self._bridge("input_action_result", {"session_id": result["session_id"], "command_id": result["command_id"]})
                if outcome.get("status") in {"released", "rejected", "unavailable"}:
                    return outcome
                if outcome.get("status") not in {"pending", "pressed"}:
                    raise ToolError("Resposta de entrada invalida.", "invalid_input_result")
            raise ToolError("A acao nao foi liberada no prazo; pare o jogo e verifique a sessao.", "input_timeout")
        if name == "godot_version":
            try:
                result = subprocess.run([str(self.godot), "--version"], cwd=self.project, capture_output=True, text=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ToolError("Falha ao consultar versao do binario.", "version_unavailable") from exc
            if result.returncode != 0:
                raise ToolError("Falha ao consultar versao do binario.", "version_failed")
            return {"version": result.stdout.strip()[:256], "binary": str(self.godot), "binary_sha256": hashlib.sha256(self.godot.read_bytes()).hexdigest()}
        if name == "godot_project_info":
            config = (self.project / "project.godot").read_bytes()
            if len(config) > 1_048_576:
                raise ToolError("project.godot maior que 1 MiB.", "project_too_large")
            try:
                lines = config.decode("utf-8-sig").splitlines()
            except UnicodeDecodeError as exc:
                raise ToolError("project.godot nao e UTF-8 valido.", "invalid_project_encoding") from exc
            selected = {}
            for line in lines:
                key, sep, value = line.partition("=")
                if sep and key.strip() in {"config/name", "run/main_scene", "renderer/rendering_method", "renderer/rendering_method.mobile", "driver/driver_name"}:
                    selected[key.strip()] = value.strip()
            return {"project_path": str(self.project), "project_godot_sha256": hashlib.sha256(config).hexdigest(), "settings_raw": selected, "note": "Valores literais do arquivo; configuracoes herdadas e resolucao UID nao interpretadas."}
        if name == "godot_capabilities":
            native_capability = "editor_disconnected"
            try:
                editor = self._bridge("status", {})
                editor_state = {"connected": True, "scene_path": editor.get("scene_path"), "playing": editor.get("playing"), "safe_scene_history": editor.get("safe_scene_history"), "unsaved_scenes": editor.get("unsaved_scenes", [])}
                try:
                    native = self._bridge("debugger_events", {})
                    native_code = native.get("error", {}).get("code") if isinstance(native.get("error"), dict) else None
                    native_capability = "available_in_session" if native.get("status") == "ok" else ("unsupported_binary" if native_code == "native_debugger_unavailable" else "session_not_proven")
                except ToolError:
                    native_capability = "bridge_operation_unavailable"
            except ToolError as exc:
                editor_state = {"connected": False, "reason": exc.code or "bridge_unavailable"}
            return {"server_version": SERVER_VERSION, "project_path": str(self.project), "permissions": {"write": self.allow_write, "run": self.allow_run, "capture": self.allow_capture, "input": self.allow_input, "script_write": self.allow_script_write, "legacy_write": self.allow_legacy_write}, "editor": editor_state, "features": {"managed_editor_process": True, "managed_game_process_logs": True, "scene_create_save_as": True, "scene_instance_checked": "requires_write_and_run_for_scene_load", "legacy_write_tools": sorted(LEGACY_WRITE_TOOLS), "checkpoint_recovery": "persistent_hash_guarded", "node_types": NODE_TYPES, "resource_uid_cache_read": True, "script_file_transaction": "single_gd_requires_opt_in", "texture_import": "single_png_configfile_reimport_checkpoint_requires_write_run", "tilemap_compose": "single_layer_png_atlas_checked", "live_2d_collector": "opt_in_per_scene", "input_action": "opt_in_per_project_and_owned_play", "native_scene_undo": "requires_custom_native_build", "native_shader_parser": "requires_custom_native_build", "mesh_library_export": "restricted_direct_child_scene_opt_in", "uid_repair": "single_closed_scene_known_ext_resource", "native_debugger_errors": native_capability, "renderer_pass_trace": False}, "note": "Disponibilidade declarada nao substitui teste no backend, GPU ou cliente atual."}
        if name == "godot_editor_launch":
            headless = args.get("headless", False)
            if type(headless) is not bool:
                raise ToolError("headless deve ser booleano.", "invalid_argument")
            try:
                status = self._bridge("status", {})
                return {"editor_connected": True, "owned": self.editor_process is not None and self.editor_process.poll() is None, "pid": self.editor_process.pid if self.editor_process and self.editor_process.poll() is None else None, "status": status}
            except ToolError:
                pass
            if self.editor_process is not None and self.editor_process.poll() is None:
                raise ToolError("Editor iniciado anteriormente ainda executa sem ponte disponivel.", "bridge_unavailable")
            command = [str(self._direct_executable()), "--editor", "--path", str(self.project)]
            if headless:
                command.insert(1, "--headless")
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            try:
                self.editor_process = subprocess.Popen(command, cwd=self.project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=flags)
            except OSError as exc:
                raise ToolError("Nao foi possivel iniciar o editor.", "editor_launch_failed") from exc
            threading.Thread(target=self._drain_process_log, args=(self.editor_process, "editor"), daemon=True).start()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if self.editor_process.poll() is not None:
                    raise ToolError("Editor encerrou antes de publicar a ponte; consulte godot_editor_log.", "editor_exited")
                try:
                    status = self._bridge("status", {})
                    return {"editor_connected": True, "owned": True, "pid": self.editor_process.pid, "headless": headless, "status": status}
                except ToolError:
                    time.sleep(0.2)
            raise ToolError("Editor nao publicou a ponte em 30 segundos; consulte godot_editor_log.", "launch_timeout")
        if name == "godot_editor_log":
            after = args.get("after_cursor", 0)
            limit = args.get("limit", 50)
            if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 100:
                raise ToolError("Cursor ou limite invalido.", "invalid_argument")
            with self.editor_log_lock:
                logs = list(self.editor_logs)
                newest = self.editor_log_seq
            entries = [entry for entry in logs if entry["cursor"] > after][:limit]
            first_retained = logs[0]["cursor"] if logs else newest + 1
            return {"origin": "owned_editor_stdout_stderr", "available": self.editor_process is not None, "entries": entries, "next_cursor": entries[-1]["cursor"] if entries else after, "newest_cursor": newest, "dropped_before_cursor": after < first_retained - 1, "truncated": len([entry for entry in logs if entry["cursor"] > after]) > limit}
        if name == "godot_editor_close":
            if self.editor_process is None or self.editor_process.poll() is not None:
                raise ToolError("Esta instancia nao possui editor ativo para encerrar.", "not_owner")
            try:
                status = self._bridge("status", {})
            except ToolError as exc:
                raise ToolError("Nao foi possivel confirmar editor limpo; processo preservado.", "editor_state_unknown") from exc
            if status.get("unsaved_scenes") or status.get("open_scripts"):
                raise ToolError("Editor tem cena nao salva ou script aberto; feche/salve antes de encerrar via MCP.", "editor_has_work", {"unsaved_scenes": status.get("unsaved_scenes"), "open_scripts": status.get("open_scripts")})
            pid = self.editor_process.pid
            if self.play_token is not None:
                try:
                    self._bridge("stop_scene", {"owner": self.owner, "play_token": self.play_token})
                except ToolError as exc:
                    raise ToolError("Stop da execucao propria falhou; editor preservado para nova tentativa.", "stop_failed", {"pid": pid}) from exc
                self.play_token = None
            self.editor_process.terminate()
            try:
                self.editor_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                raise ToolError("Editor nao encerrou; processo continua sob esta instancia.", "close_timeout", {"pid": pid})
            return {"closed": True, "pid": pid, "exit_code": self.editor_process.returncode}
        if name == "godot_run_project":
            headless = args.get("headless", False)
            method = args.get("rendering_method")
            if type(headless) is not bool or (method is not None and method not in {"gl_compatibility", "forward_plus", "mobile"}):
                raise ToolError("Argumentos de execucao invalidos.", "invalid_argument")
            if self.game_process is not None and self.game_process.poll() is None:
                raise ToolError("Esta instancia ja executa um jogo.", "already_running")
            command = [str(self._direct_executable()), "--path", str(self.project)]
            if headless:
                command.insert(1, "--headless")
            if method is not None:
                command += ["--rendering-method", method]
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            try:
                self.game_process = subprocess.Popen(command, cwd=self.project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=flags)
            except OSError as exc:
                raise ToolError("Nao foi possivel iniciar o projeto.", "project_launch_failed") from exc
            self.game_run_id = uuid.uuid4().hex
            threading.Thread(target=self._drain_process_log, args=(self.game_process, "game", self.game_run_id), daemon=True).start()
            return {"started": True, "pid": self.game_process.pid, "run_id": self.game_run_id, "headless": headless, "rendering_method_requested": method, "project_path": str(self.project), "note": "Consulte godot_project_log e confirme o backend por amostra viva quando disponivel."}
        if name == "godot_project_log":
            after = args.get("after_cursor", 0)
            limit = args.get("limit", 50)
            if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 100:
                raise ToolError("Cursor ou limite invalido.", "invalid_argument")
            with self.game_log_lock:
                logs = list(self.game_logs)
                newest = self.game_log_seq
            entries = [entry for entry in logs if entry["cursor"] > after][:limit]
            first_retained = logs[0]["cursor"] if logs else newest + 1
            return {"origin": "owned_game_stdout_stderr", "available": self.game_process is not None, "run_id": self.game_run_id, "running": self.game_process is not None and self.game_process.poll() is None, "exit_code": self.game_process.returncode if self.game_process else None, "entries": entries, "next_cursor": entries[-1]["cursor"] if entries else after, "newest_cursor": newest, "dropped_before_cursor": after < first_retained - 1, "truncated": len([entry for entry in logs if entry["cursor"] > after]) > limit}
        if name == "godot_stop_project":
            if self.game_process is None or self.game_process.poll() is not None:
                raise ToolError("Esta instancia nao possui jogo ativo para encerrar.", "not_owner")
            pid = self.game_process.pid
            self.game_process.terminate()
            try:
                self.game_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                raise ToolError("O jogo nao encerrou; processo continua sob esta instancia.", "stop_timeout", {"pid": pid})
            return {"stopped": True, "pid": pid, "exit_code": self.game_process.returncode}
        if name == "godot_play_scene":
            if self.play_token is not None:
                raise ToolError("Esta instancia ja iniciou uma execucao; pare-a antes de reiniciar.", "already_owned")
            mode = args.get("mode")
            if mode not in {"current", "main", "path"}:
                raise ToolError("Modo invalido.", "invalid_mode")
            request = {"mode": mode, "owner": self.owner}
            if mode == "path":
                path = self._project_file(args.get("path", ""), {".tscn"})
                request["path"] = "res://" + path.relative_to(self.project).as_posix()
            reply = self._bridge("play_scene", request)
            self.play_token = reply["play_token"]
            return {key: value for key, value in reply.items() if key != "play_token"}
        if name == "godot_stop_scene":
            if self.play_token is None:
                raise ToolError("Esta instancia nao possui execucao para parar.", "not_owner")
            reply = self._bridge("stop_scene", {"owner": self.owner, "play_token": self.play_token})
            self.play_token = None
            return {key: value for key, value in reply.items() if key != "play_token"}
        if name == "godot_graphics_report":
            return graphics_report(self.call("godot_live_snapshot", args))
        if name == "godot_graphics_compare":
            if not self.allow_capture:
                raise ToolError("Comparacao exige --allow-capture.", "capture_disabled")
            if len(self.graphics_captures) != 2:
                return {"status": "unavailable", "error": {"code": "two_captures_required"}}
            return graphics_compare(*self.graphics_captures)
        if name == "godot_live_evidence":
            return self._live_evidence(args)
        if name == "godot_live_image":
            if not self.allow_capture:
                raise ToolError("Captura de pixels bloqueada. Inicie o servidor com --allow-capture para este projeto.", "capture_disabled")
            session_id = args.get("session_id")
            if session_id is not None and (type(session_id) is not int or session_id < 0):
                raise ToolError("session_id deve ser um inteiro nao negativo.")
            viewport_path = args.get("viewport_path", "")
            if not isinstance(viewport_path, str) or len(viewport_path) > 512:
                raise ToolError("viewport_path invalido.", "invalid_viewport")
            pixel = args.get("pixel")
            if pixel is not None and (not isinstance(pixel, list) or len(pixel) != 2 or any(type(v) not in (float, int) or not math.isfinite(v) or not 0 <= v < 2048 for v in pixel)):
                raise ToolError("pixel deve conter duas coordenadas finitas entre 0 e 2048.", "invalid_pixel")
            tool_started = time.perf_counter_ns()
            started = self._bridge("live_image_start", dict({} if session_id is None else {"session_id": session_id}, viewport_path=viewport_path))
            start_bridge_ms = (time.perf_counter_ns() - tool_started) / 1_000_000
            if started.get("status") != "pending":
                if started.get("status") != "unavailable" or not isinstance(started.get("error"), dict):
                    raise ToolError("Estado inicial da captura invalido.", "invalid_image")
                return started
            capture_id = started.get("capture_id")
            selected_session = started.get("session_id")
            if not isinstance(capture_id, str) or len(capture_id) != 32 or type(selected_session) is not int:
                raise ToolError("Identidade da captura invalida.", "invalid_image")
            deadline = time.monotonic() + 11
            poll_count = 0
            poll_bridge_ms = 0.0
            while time.monotonic() < deadline:
                time.sleep(IMAGE_POLL_SECONDS)
                poll_started = time.perf_counter_ns()
                result = self._bridge("live_image_result", {"session_id": selected_session, "capture_id": capture_id})
                poll_count += 1
                poll_bridge_ms += (time.perf_counter_ns() - poll_started) / 1_000_000
                if result.get("status") == "pending":
                    continue
                if result.get("status") not in {"ready", "unavailable"}:
                    raise ToolError("Estado final da captura invalido.", "invalid_image")
                if result.get("status") == "ready":
                    self._validate_image(result, capture_id, selected_session)
                    if pixel is not None:
                        if pixel[0] >= result["width"] or pixel[1] >= result["height"]:
                            raise ToolError("Pixel fora do viewport capturado.", "invalid_pixel")
                        result["pixel_candidates"] = graphics_pick(result.get("frame_context", {}), pixel)
                    self.graphics_captures.append({key: value for key, value in result.items() if key != "image_base64"})
                elif not isinstance(result.get("error"), dict):
                    raise ToolError("Erro de captura sem codigo.", "invalid_image")
                result["mcp_image_timing_ms"] = {"start_bridge": round(start_bridge_ms, 3), "poll_bridge_total": round(poll_bridge_ms, 3), "poll_count": poll_count, "sleep_requested_total": round(poll_count * IMAGE_POLL_SECONDS * 1000.0, 3), "tool_before_response": round((time.perf_counter_ns() - tool_started) / 1_000_000, 3)}
                result["editor_request_dispatch_usec"] = started.get("editor_request_dispatch_usec")
                result["editor_send_call_usec"] = started.get("editor_send_call_usec")
                return result
            raise ToolError("Tempo esgotado aguardando imagem do jogo.", "capture_timeout")
        if name in {"godot_graphics_asset", "godot_graphics_edit_checked"}:
            args = dict(args)
            if name == "godot_graphics_asset":
                raw = args.get("path")
                raw = raw.removeprefix("res://") if isinstance(raw, str) else raw
                path = self._project_file(raw, {".png", ".jpg", ".jpeg", ".webp", ".gdshader"})
                args["path"] = "res://" + path.relative_to(self.project).as_posix()
            else:
                changes = args.get("changes")
                if not isinstance(changes, dict):
                    raise ToolError("changes deve ser um objeto.", "invalid_changes")
                for key in ("texture_path", "shader_path"):
                    if key in changes:
                        raw = changes[key]
                        raw = raw.removeprefix("res://") if isinstance(raw, str) else raw
                        suffixes = {".gdshader"} if key == "shader_path" else {".png", ".jpg", ".jpeg", ".webp"}
                        self._project_file(raw, suffixes)
        if name in BRIDGE_OPS:
            if name == "godot_tilemap_compose_checked":
                raw = args.get("texture_path")
                raw = raw.removeprefix("res://") if isinstance(raw, str) else raw
                texture = self._project_file(raw, {".png"})
                expected = args.get("texture_sha256")
                if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                    raise ToolError("texture_sha256 invalido.", "invalid_hash")
                if texture.stat().st_size > 1_048_576 or hashlib.sha256(texture.read_bytes()).hexdigest() != expected:
                    raise ToolError("Textura excede limite ou mudou.", "hash_conflict")
                args = dict(args, texture_path="res://" + texture.relative_to(self.project).as_posix())
            if name == "godot_open_scene_checked":
                raw = args.get("path")
                raw = raw.removeprefix("res://") if isinstance(raw, str) else raw
                target = self._project_file(raw, {".tscn"})
                expected = args.get("expected_active_scene_path")
                sha = args.get("expected_target_sha256")
                if ("expected_active_scene_path" not in args or (expected is not None and not isinstance(expected, str))
                        or (sha is not None and (not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha)))
                        or type(args.get("dry_run", False)) is not bool):
                    raise ToolError("Precondicoes da cena invalidas.", "invalid_precondition")
                args = dict(args, path="res://" + target.relative_to(self.project).as_posix())
            if name in {"godot_save_scene_checked", "godot_remove_leaf_checked", "godot_history_action_checked"}:
                if (not isinstance(args.get("expected_scene_path"), str) or not isinstance(args.get("expected_graph_revision"), str)
                        or not re.fullmatch(r"[0-9a-f]{64}", args["expected_graph_revision"])):
                    raise ToolError("Cena ou revisao esperada invalida.", "invalid_precondition")
                if name == "godot_save_scene_checked" and (not isinstance(args.get("expected_disk_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", args["expected_disk_sha256"])):
                    raise ToolError("SHA-256 esperado invalido.", "invalid_hash")
                if name == "godot_history_action_checked" and (args.get("direction") not in {"undo", "redo"} or type(args.get("expected_history_id")) is not int or type(args.get("expected_action_index")) is not int or not isinstance(args.get("expected_action_name"), str)):
                    raise ToolError("Precondicoes de historico invalidas.", "invalid_precondition")
                if name in {"godot_save_scene_checked", "godot_remove_leaf_checked"} and type(args.get("dry_run", False)) is not bool:
                    raise ToolError("dry_run precisa ser booleano.", "invalid_argument")
            if name == "godot_debugger_events":
                for field in ("session_id", "run_generation", "after_cursor"):
                    if field in args and (type(args[field]) is not int or not 0 <= args[field] <= 9_007_199_254_740_991):
                        raise ToolError(f"{field} deve ser inteiro nao negativo.", "invalid_query")
                if "limit" in args and (type(args["limit"]) is not int or not 1 <= args["limit"] <= 40):
                    raise ToolError("limit deve estar entre 1 e 40.", "invalid_query")
                args = {key: args[key] for key in ("session_id", "run_generation", "after_cursor", "limit") if key in args}
            if name in {"godot_create_scene", "godot_save_scene_as_checked", "godot_revert_created_scene"}:
                args = dict(args, path=self._new_scene_path(args.get("path")))
                if name == "godot_revert_created_scene":
                    self._assert_scene_unreferenced(args["path"])
            elif name == "godot_instance_scene_checked":
                source = self._project_file(args.get("source_path", ""), {".tscn"})
                expected_source_sha256 = args.get("expected_source_sha256")
                if not isinstance(expected_source_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256):
                    raise ToolError("expected_source_sha256 invalido.", "invalid_hash")
                if hashlib.sha256(source.read_bytes()).hexdigest() != expected_source_sha256:
                    raise ToolError("Subcena mudou desde a leitura.", "hash_conflict")
                args = dict(args, source_path="res://" + source.relative_to(self.project).as_posix())
            elif name == "godot_resource_uid":
                raw = args.get("path")
                raw = raw.removeprefix("res://") if isinstance(raw, str) else raw
                path = self._project_file(raw, {".tscn", ".tres", ".gd", ".gdshader", ".png", ".jpg", ".jpeg", ".webp", ".svg", ".ogg", ".wav", ".glb", ".gltf"})
                args = {"path": "res://" + path.relative_to(self.project).as_posix()}
            if name == "godot_open_scene":
                raw_path = args.get("path")
                path = self._project_file(raw_path, {".tscn"})
                args = {"path": "res://" + path.relative_to(self.project).as_posix()}
            elif name in {"godot_live_snapshot", "godot_live_timeline"}:
                requested_args = args
                session_id = args.get("session_id")
                if session_id is not None and (type(session_id) is not int or session_id < 0):
                    raise ToolError("session_id deve ser um inteiro nao negativo.")
                args = {} if session_id is None else {"session_id": session_id}
                if name == "godot_live_timeline" and "limit" in requested_args:
                    limit = requested_args["limit"]
                    if type(limit) is not int or not 1 <= limit <= 40:
                        raise ToolError("limit deve estar entre 1 e 40.")
                    args["limit"] = limit
            return self._bridge(BRIDGE_OPS[name], args)
        if name == "godot_list_files":
            limit = args.get("limit", 200)
            if type(limit) is not int or not 1 <= limit <= 500:
                raise ToolError("limit deve estar entre 1 e 500.")
            files = []
            for base, dirs, names in os.walk(self.project, followlinks=False):
                kept = []
                for directory in sorted(dirs):
                    if directory in SKIP_DIRS or directory.startswith("."):
                        continue
                    child = Path(base) / directory
                    if child.is_symlink() or getattr(child, "is_junction", lambda: False)():
                        continue
                    kept.append(directory)
                dirs[:] = kept
                for file_name in sorted(names):
                    candidate = Path(base) / file_name
                    if candidate.suffix.lower() in LISTABLE_SUFFIXES and not candidate.is_symlink() and not getattr(candidate, "is_junction", lambda: False)() and candidate.resolve().is_relative_to(self.project):
                        files.append(candidate.relative_to(self.project).as_posix())
                        if len(files) >= limit:
                            return {"files": files, "truncated": True, "limit": limit}
            return {"files": files, "truncated": False, "limit": limit}
        if name == "godot_read_text":
            path = self._project_file(args.get("path"), READABLE_SUFFIXES)
            if path.stat().st_size > 131072:
                raise ToolError("Arquivo maior que o limite de leitura (128 KiB).")
            try:
                contents = path.read_text(encoding="utf-8")
            except (UnicodeError, OSError) as exc:
                raise ToolError("Arquivo nao pode ser lido como UTF-8.") from exc
            return {"path": path.relative_to(self.project).as_posix(), "text": contents}
        if name == "godot_validate":
            return self._validate(args.get("mode"), args.get("test_path"))
        raise ToolError("Ferramenta sem implementacao.")

    def _direct_executable(self) -> Path:
        direct = Path(str(self.godot).removesuffix(".console.exe") + ".exe") if str(self.godot).lower().endswith(".console.exe") else self.godot
        return direct if direct.is_file() else self.godot

    def _drain_process_log(self, process: subprocess.Popen[bytes], channel: str, run_id: str | None = None) -> None:
        if process.stdout is None:
            return
        while chunk := process.stdout.readline(8192):
            line = chunk.decode("utf-8", errors="replace").rstrip("\r\n")
            severity = "error" if "ERROR" in line else "warning" if "WARNING" in line else "info"
            location = re.search(r"(?:res://[^\s()]+|[A-Za-z]:[/\\][^\s()]+):([0-9]{1,7})", line)
            lock = self.editor_log_lock if channel == "editor" else self.game_log_lock
            with lock:
                if channel == "editor":
                    self.editor_log_seq += 1
                    cursor = self.editor_log_seq
                    target = self.editor_logs
                else:
                    self.game_log_seq += 1
                    cursor = self.game_log_seq
                    target = self.game_logs
                target.append({"cursor": cursor, "run_id": run_id, "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "severity": severity, "text": line[:8192], "location": location.group(0) if location else None, "origin": channel + "_process_output"})

    def shutdown(self) -> None:
        play_stop_failed = False
        if self.play_token is not None:
            try:
                self._bridge("stop_scene", {"owner": self.owner, "play_token": self.play_token})
            except ToolError:
                play_stop_failed = True
                print("Stop do Play proprio falhou no EOF; editor sera preservado.", file=sys.stderr)
            else:
                self.play_token = None
        process = self.editor_process
        if process is not None and process.poll() is None:
            # EOF nao autoriza perder buffers humanos; preservar tambem se a ponte falhou.
            try:
                status = self._bridge("status", {})
                clean = status.get("unsaved_scenes") == [] and status.get("open_scripts") == []
            except ToolError:
                clean = False
            if clean and not play_stop_failed:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    print("Editor proprio nao encerrou no prazo; processo preservado.", file=sys.stderr)
            else:
                print(f"Editor proprio PID {process.pid} preservado: estado limpo nao confirmado.", file=sys.stderr)
        process = self.game_process
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def _live_evidence(self, args: dict[str, Any]) -> dict[str, Any]:
        if not self.allow_capture:
            raise ToolError("Captura de pixels bloqueada. Inicie o servidor com --allow-capture para este projeto.", "capture_disabled")
        session_id = args.get("session_id")
        if session_id is not None and (type(session_id) is not int or session_id < 0):
            raise ToolError("session_id deve ser um inteiro nao negativo.", "invalid_session")
        timeline_limit = args.get("timeline_limit", 12)
        if type(timeline_limit) is not int or not 1 <= timeline_limit <= 20:
            raise ToolError("timeline_limit deve estar entre 1 e 20.", "invalid_limit")
        node_paths = args.get("node_paths", ["ScoreLabel"])
        if not isinstance(node_paths, list) or len(node_paths) > 20 or any(not isinstance(path, str) or not path or len(path) > 256 for path in node_paths):
            raise ToolError("node_paths deve conter ate 20 caminhos de no com no maximo 256 caracteres.", "invalid_node_paths")
        if len(node_paths) != len(set(node_paths)):
            raise ToolError("node_paths nao pode repetir caminhos.", "invalid_node_paths")

        requested = {} if session_id is None else {"session_id": session_id}
        before = self._bridge("live_snapshot", requested)
        if before.get("status") != "ok":
            return {"status": "unavailable", "error": {"code": "sample_unavailable", "message": "A amostra inicial nao esta atual."}, "before": {"status": before.get("status"), "age_ms": before.get("age_ms"), "error": before.get("error")}}
        selected_session = before["session_id"]
        image = self.call("godot_live_image", {"session_id": selected_session, "viewport_path": args.get("viewport_path", "")})
        if image.get("status") != "ready":
            return {"status": "unavailable", "error": image.get("error", {"code": "capture_unavailable"}), "before": {"status": before["status"], "sample_seq": before["sample"].get("sample_seq"), "age_ms": before["age_ms"]}}
        after = self._bridge("live_snapshot", {"session_id": selected_session})
        if after.get("status") != "ok":
            return {"status": "unavailable", "error": {"code": "sample_unavailable_after_capture", "message": "A amostra posterior nao esta atual; a correlacao foi recusada."}, "after": {"status": after.get("status"), "age_ms": after.get("age_ms"), "error": after.get("error")}, "image_sha256": image["sha256"]}
        first = before["sample"]
        last = after["sample"]
        identity = (first.get("run_id"), first.get("scene_path"), first.get("backend"))
        if identity != (last.get("run_id"), last.get("scene_path"), last.get("backend")) or image.get("run_id") != first.get("run_id") or image.get("scene_path") != first.get("scene_path") or image.get("backend") != first.get("backend"):
            return {"status": "unavailable", "error": {"code": "session_changed", "message": "Cena, execucao ou backend mudou durante a coleta."}, "image_sha256": image["sha256"]}
        timeline = self._bridge("live_timeline", {"session_id": selected_session, "limit": timeline_limit})
        if timeline.get("run_id") != first.get("run_id"):
            return {"status": "unavailable", "error": {"code": "session_changed", "message": "A linha do tempo pertence a outra execucao."}, "image_sha256": image["sha256"]}
        events = [event for event in timeline.get("events", []) if event.get("run_id") == first.get("run_id")]
        unattributed_rejections = [event for event in timeline.get("events", []) if event.get("kind") == "rejected" and "run_id" not in event]
        selected_nodes = [node for node in last.get("nodes", []) if node.get("path") in node_paths]
        found_paths = {node.get("path") for node in selected_nodes}
        try:
            graph = self._bridge("dependency_graph", {})
            source_links = [edge for edge in graph.get("edges", []) if edge.get("relation") in {"persistent_signal", "scene_instance"} or (edge.get("relation") == "node_resource_property" and str(edge.get("to", "")).endswith(".gd"))]
            graph_summary = {"status": "ok", "scene_path": graph.get("scene_path"), "revision": graph.get("revision"), "counts": {"nodes": len(graph.get("nodes", [])), "resources": len(graph.get("resources", [])), "edges": len(graph.get("edges", [])), "unknown": len(graph.get("unknown", []))}, "truncated": graph.get("truncated"), "same_scene_as_runtime": graph.get("scene_path") == first.get("scene_path"), "relationship": "editor_current_projection_not_runtime_snapshot", "source_links": source_links[:32], "source_links_truncated": len(source_links) > 32, "source_links_causality": "unproven"}
        except ToolError as exc:
            graph_summary = {"status": "unavailable", "error": {"code": exc.code or "editor_graph_unavailable", "message": str(exc)}}

        image_metadata = {key: value for key, value in image.items() if key != "image_base64"}
        before_frame = first.get("render_frame")
        after_frame = last.get("render_frame")
        image_frame = image.get("render_frame")
        return {
            "status": "ready", "schema_version": 1, "origin": "composed_editor_runtime_evidence",
            "image_base64": image["image_base64"], "image": image_metadata,
            "session_id": selected_session, "run_id": first["run_id"], "scene_path": first["scene_path"], "backend": first["backend"],
            "before": {"sample_seq": first.get("sample_seq"), "render_frame": before_frame, "age_ms_at_read": before["age_ms"], "received_ticks_usec": before.get("received_ticks_usec"), "received_utc": before.get("received_utc")},
            "after": {"sample_seq": last.get("sample_seq"), "render_frame": after_frame, "age_ms_at_read": after["age_ms"], "received_ticks_usec": after.get("received_ticks_usec"), "received_utc": after.get("received_utc"), "viewport": last.get("viewport"), "performance": last.get("performance"), "collect_usec": last.get("collect_usec"), "nodes": selected_nodes, "requested_node_paths_missing": [path for path in node_paths if path not in found_paths], "nodes_truncated": last.get("nodes_truncated", False)},
            "timeline": {"origin": timeline.get("origin"), "events": events, "unattributed_receiver_rejections": unattributed_rejections, "truncated": timeline.get("truncated"), "dropped_event_count": timeline.get("dropped_event_count"), "receiver_last_capture_usec": timeline.get("receiver_last_capture_usec"), "error": timeline.get("error")},
            "editor_graph": graph_summary,
            "errors": {"sample_receiver": after.get("error"), "timeline_receiver": timeline.get("error"), "unattributed_rejections": unattributed_rejections, "native_runtime": "not_collected"},
            "correlation": {"same_run_scene_backend": True, "image_frame_minus_before_sample": image_frame - before_frame if type(image_frame) is int and type(before_frame) is int else None, "after_sample_minus_image_frame": after_frame - image_frame if type(image_frame) is int and type(after_frame) is int else None, "after_read_sample_is_older_than_image": after_frame < image_frame if type(image_frame) is int and type(after_frame) is int else None, "pixel_metric_same_frame": "unproven", "editor_graph_matches_runtime_content": "unproven", "native_editor_monitor_comparison": "not_collected", "native_debugger_errors": "separate_tool_native_generation_not_correlated", "dynamic_script_dependencies": "unobserved"},
        }

    @staticmethod
    def _validate_image(result: dict[str, Any], capture_id: str, session_id: int) -> None:
        if result.get("capture_id") != capture_id or result.get("session_id") != session_id or result.get("origin") != "runtime_viewport_readback":
            raise ToolError("Origem ou identidade da imagem nao confere.", "invalid_image")
        encoded = result.get("image_base64")
        if not isinstance(encoded, str) or len(encoded) > 349528:
            raise ToolError("Imagem excede o limite de transporte.", "image_bytes_exceeded")
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise ToolError("Imagem base64 invalida.", "invalid_image") from exc
        if not 24 <= len(raw) <= 262144 or raw[:8] != b"\x89PNG\r\n\x1a\n" or raw[12:16] != b"IHDR":
            raise ToolError("Cabecalho PNG invalido.", "invalid_image")
        width, height = struct.unpack(">II", raw[16:24])
        if not 1 <= width <= 2048 or not 1 <= height <= 2048 or (width, height) != (result.get("width"), result.get("height")):
            raise ToolError("Dimensoes PNG nao conferem.", "invalid_image")
        if result.get("png_bytes") != len(raw) or result.get("sha256") != hashlib.sha256(raw).hexdigest():
            raise ToolError("Tamanho ou checksum PNG nao confere.", "invalid_image")

    def _validate(self, mode: Any, test_path: Any = None) -> dict[str, Any]:
        if mode not in {"import", "run", "test"}:
            raise ToolError("mode deve ser import, run ou test.")
        command = [str(self.godot), "--headless", "--path", str(self.project)]
        if mode == "import":
            command += ["--editor", "--quit"]
        elif mode == "run":
            command += ["--quit-after", "30"]
        else:
            path = self._project_file(test_path, {".gd"})
            relative = path.relative_to(self.project)
            if not relative.parts or relative.parts[0] != "tests":
                raise ToolError("Scripts de teste precisam estar em tests/.")
            command += ["--script", "res://" + relative.as_posix()]
        try:
            completed = subprocess.run(command, cwd=self.project, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90, check=False)
        except subprocess.TimeoutExpired as exc:
            raise ToolError("Godot excedeu 90 segundos e foi encerrada.", "validation_timeout") from exc
        except OSError as exc:
            raise ToolError("Godot nao iniciou validacao.", "validation_unavailable") from exc
        output = (completed.stdout + completed.stderr)[-30000:]
        error_lines = [line.strip() for line in output.splitlines() if "ERROR" in line.upper() or "PARSE ERROR" in line.upper()]
        return {"mode": mode, "ok": completed.returncode == 0 and not error_lines, "exit_code": completed.returncode, "errors": error_lines[:30], "output": output, "truncated": len(completed.stdout) + len(completed.stderr) > 30000}


def _response(message_id: Any, result: Any = None, error: dict[str, Any] | None = None) -> dict[str, Any]:
    response = {"jsonrpc": "2.0", "id": message_id}
    if error is None:
        response["result"] = result
    else:
        response["error"] = error
    return response


def _tool_result(value: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}], "structuredContent": value, "isError": is_error}


def _image_tool_result(value: dict[str, Any]) -> dict[str, Any]:
    if value.get("status") != "ready":
        return _tool_result(value)
    metadata = {key: item for key, item in value.items() if key != "image_base64"}
    return {"content": [{"type": "text", "text": json.dumps(metadata, ensure_ascii=False)}, {"type": "image", "data": value["image_base64"], "mimeType": "image/png"}], "structuredContent": metadata, "isError": False}


def _modern_result(value: dict[str, Any]) -> dict[str, Any]:
    return {"resultType": "complete", **value, "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "mcp-for-godot", "version": SERVER_VERSION}}}


def handle_message(server: GodotMCP, message: Any) -> dict[str, Any] | None:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return _response(None, error={"code": -32600, "message": "Invalid Request"})
    if "id" not in message:
        return None  # notificacoes nao exigem resposta
    message_id = message["id"]
    method = message.get("method")
    params = message.get("params", {})
    if not isinstance(params, dict):
        return _response(message_id, error={"code": -32602, "message": "Invalid params"})
    meta = params.get("_meta")
    modern = isinstance(meta, dict) and "io.modelcontextprotocol/protocolVersion" in meta
    if meta is not None and not isinstance(meta, dict):
        return _response(message_id, error={"code": -32602, "message": "Invalid params: _meta must be an object"})
    if modern:
        if not isinstance(meta, dict) or not isinstance(meta.get("io.modelcontextprotocol/protocolVersion"), str) or not isinstance(meta.get("io.modelcontextprotocol/clientCapabilities"), dict):
            return _response(message_id, error={"code": -32602, "message": "Invalid params: missing request metadata"})
        requested_version = meta["io.modelcontextprotocol/protocolVersion"]
        if requested_version != MODERN_PROTOCOL_VERSION:
            return _response(message_id, error={"code": -32022, "message": "Unsupported protocol version", "data": {"supported": [MODERN_PROTOCOL_VERSION, PROTOCOL_VERSION], "requested": requested_version}})
    elif method != "initialize" and not server.legacy_initialized:
        return _response(message_id, error={"code": -32602, "message": "Invalid params: request metadata or legacy initialization required"})
    if method == "server/discover" and modern:
        return _response(message_id, _modern_result({"supportedVersions": [MODERN_PROTOCOL_VERSION, PROTOCOL_VERSION], "capabilities": {"tools": {"listChanged": False}}, "instructions": "Acesso limitado ao projeto configurado. Escrita, execucao e captura exigem flags locais distintas.", "ttlMs": 300000, "cacheScope": "public"}))
    if method == "initialize":
        if modern:
            return _response(message_id, error={"code": -32601, "message": "Method not found in modern protocol"})
        server.legacy_initialized = True
        client_info = params.get("clientInfo")
        if isinstance(client_info, dict) and isinstance(client_info.get("name"), str):
            server.client_name = client_info["name"][:80]
        return _response(message_id, {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "mcp-for-godot", "version": SERVER_VERSION}, "instructions": "O acesso esta limitado ao projeto configurado. Escrita e execucao exigem flags locais distintas."})
    if method == "ping":
        return _response(message_id, _modern_result({}) if modern else {})
    if method == "tools/list":
        cursor = params.get("cursor")
        if cursor is not None:
            return _response(message_id, error={"code": -32602, "message": "Invalid params: unknown cursor"})
        visible = _visible_tools(server)
        value = {"tools": visible, "ttlMs": 300000, "cacheScope": "private"} if modern else {"tools": visible}
        return _response(message_id, _modern_result(value) if modern else value)
    if method == "tools/call":
        if not isinstance(params, dict) or not isinstance(params.get("name"), str) or not isinstance(params.get("arguments", {}), dict):
            return _response(message_id, error={"code": -32602, "message": "Invalid params"})
        server.current_trace_id = uuid.uuid4().hex
        try:
            value = server.call(params["name"], params.get("arguments", {}))
            value = dict(value)
            value["audit_logged"] = server._audit(message_id, params["name"], params.get("arguments", {}), "ok")
            if not value["audit_logged"]:
                print(f"Registro de operacao indisponivel: {params['name']}", file=sys.stderr)
            result = _image_tool_result(value) if params["name"] in {"godot_live_image", "godot_live_evidence"} else _tool_result(value)
            return _response(message_id, _modern_result(result) if modern else result)
        except ToolError as exc:
            logged = server._audit(message_id, params["name"], params.get("arguments", {}), exc.code or "tool_error")
            if not logged:
                print(f"Registro de operacao indisponivel: {params['name']}", file=sys.stderr)
            if exc.code is not None:
                result = _tool_result({"error": {"code": exc.code, "message": str(exc), "details": exc.details}, "audit_logged": logged}, True)
            else:
                result = _tool_result({"error": str(exc), "audit_logged": logged}, True)
            return _response(message_id, _modern_result(result) if modern else result)
        except Exception as exc:  # nunca corromper stdout do transporte
            print(f"Erro interno em {params['name']}: {exc!r}", file=sys.stderr)
            logged = server._audit(message_id, params["name"], params.get("arguments", {}), "internal_error")
            result = _tool_result({"error": "Erro interno da ferramenta. Consulte stderr do servidor.", "audit_logged": logged}, True)
            return _response(message_id, _modern_result(result) if modern else result)
        finally:
            server.current_trace_id = None
    return _response(message_id, error={"code": -32601, "message": "Method not found"})


def main() -> int:
    # No Windows o terminal pode usar cp1252, mas o transporte MCP exige UTF-8.
    sys.stdout.reconfigure(encoding="utf-8", errors="strict", newline="\n")
    parser = argparse.ArgumentParser(description="Servidor MCP stdio para um unico projeto Godot local")
    parser.add_argument("--project", type=Path, required=True, help="Pasta com project.godot")
    parser.add_argument("--godot", type=Path, required=True, help="Executavel console da Godot 4.7.2")
    parser.add_argument("--allow-write", action="store_true", help="Permite editar e salvar a cena ativa")
    parser.add_argument("--allow-run", action="store_true", help="Permite executar validacoes Godot headless")
    parser.add_argument("--allow-capture", action="store_true", help="Permite expor pixels do jogo conectado ao depurador")
    parser.add_argument("--allow-input", action="store_true", help="Permite acoes InputMap explicitamente autorizadas na cena depurada")
    parser.add_argument("--allow-script-write", action="store_true", help="Permite patch de codigo executavel .gd com transacao e validacao isolada")
    parser.add_argument("--allow-legacy-write", action="store_true", help="Habilita atalhos legados de edicao sem precondicoes; use somente em projeto descartavel")
    options = parser.parse_args()
    try:
        server = GodotMCP(options.project, options.godot, options.allow_write, options.allow_run, options.allow_capture, options.allow_input, options.allow_script_write, options.allow_legacy_write)
    except (OSError, ValueError) as exc:
        print(f"Falha ao iniciar: {exc}", file=sys.stderr)
        return 2
    try:
        while True:
            raw_line = sys.stdin.buffer.readline(MAX_MCP_LINE + 1)
            if not raw_line:
                break
            if len(raw_line) > MAX_MCP_LINE:
                if not raw_line.endswith(b"\n"):
                    while True:
                        remainder = sys.stdin.buffer.readline(65536)
                        if not remainder or remainder.endswith(b"\n"):
                            break
                response = _response(None, error={"code": -32700, "message": "Message too large"})
            else:
                try:
                    response = handle_message(server, json.loads(raw_line))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    response = _response(None, error={"code": -32700, "message": "Parse error"})
            if response is not None:
                sys.stdout.write(json.dumps(response, ensure_ascii=True, separators=(",", ":")) + "\n")
                sys.stdout.flush()
    finally:
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
