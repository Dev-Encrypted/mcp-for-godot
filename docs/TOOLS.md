# Tool catalog

Generated from `mcp_for_godot.server` version 0.10.0. Do not edit by hand.

Total: **65 tools**.

| Tool | Visibility gate | Canonical summary |
|---|---|---|
| `godot_add_node` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Adiciona um no de tipo permitido a cena ativa, usando o historico Desfazer/Refazer do editor. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_add_node_checked` | `--allow-write` | Previsualiza ou cria um no permitido com ate oito propriedades tipadas somente se cena e revisao do grafo coincidirem; Desfazer/Refazer. Exige --allow-write. |
| `godot_capabilities` | Read-only baseline | Declara capacidades e permissoes efetivas desta instancia, separando ponte ativa, APIs publicas e extensoes do fork. |
| `godot_checkpoint_list` | `--allow-write` | Lista checkpoints persistidos do projeto, com estado por hash e sem conteudo. Exige --allow-write. |
| `godot_close_scene_checked` | `--allow-write` | Fecha apenas a cena ativa esperada e salva; recusa perder alteracoes pendentes. Exige --allow-write. |
| `godot_connect_signal_checked` | `--allow-write` | Previsualiza ou conecta sinal persistente de dois nos da cena editada a metodo _on_ de script, com revisao do grafo e Desfazer/Refazer. Exige --allow-write. |
| `godot_create_scene` | `--allow-write` | Cria uma cena nova em diretorio existente, sem sobrescrever; pre-visualizacao e compensacao com hash. Exige --allow-write. |
| `godot_debugger_events` | Read-only baseline | Le erros e saida do depurador nativo do Play no editor com cursor e identidade de sessao/geracao. Nao confunde geracao nativa com run_id da amostra grafica. |
| `godot_dependency_graph` | Read-only baseline | Mapeia nos da cena editada, scripts, sinais persistentes e dependencias declaradas de recursos; informa origem, ausencias e truncamento. |
| `godot_editor_close` | `--allow-run` | Encerra somente o editor iniciado por esta instancia MCP. Exige --allow-run. |
| `godot_editor_launch` | `--allow-run` | Conecta ao editor existente ou inicia um editor do projeto fixado e o gerencia nesta instancia. Exige --allow-run. |
| `godot_editor_log` | Read-only baseline | Le buffer limitado da saida do editor iniciado nesta instancia, com cursor; indisponivel para editor externo. |
| `godot_gameplay_attach_script_checked` | `--allow-write`, `--allow-script-write` | Previa de associacao de script exige --allow-write e --allow-script-write; aplicar carrega codigo e exige tambem --allow-run. |
| `godot_gameplay_compose_checked` | `--allow-write` | Previsualiza ou compoe ate 24 nos tipados 2D/3D em uma acao de historico da cena, com revisao e recursos restritos. Exige --allow-write. |
| `godot_graphics_asset` | Read-only baseline | Le hash e metadados de importacao de textura PNG/JPEG/WebP; valida fonte .gdshader pelo parser nativo, sem compilar pipeline GPU ou alterar importacao. |
| `godot_graphics_compare` | `--allow-capture` | Compara metadados das duas ultimas capturas deste cliente: identidade, hash PNG e tempos. Exige --allow-capture; diferenca nao prova regressao nem ganho de desempenho. |
| `godot_graphics_edit_checked` | `--allow-write` | Previsualiza/aplica alteracoes de CanvasItem, textura, shader e parametros; exige revisao, hashes dos recursos novos, --allow-write e suporta Desfazer/Refazer. Duplica material para preservar consumidores. |
| `godot_graphics_inspect` | Read-only baseline | Inspeciona propriedades graficas e recursos carregados de um CanvasItem da cena editada, com revisao para controle protegido. |
| `godot_graphics_report` | Read-only baseline | Relata tempos e contadores observados, capacidades ausentes e hipoteses de batching/variacao de frames. Nao afirma causa nem aplica otimizacao. |
| `godot_history_action_checked` | `--allow-write` | Executa undo/redo somente com cena, revisao, historico, indice e nome exatos. Exige --allow-write. |
| `godot_history_state` | Read-only baseline | Le identidade, indice e nome da acao no historico da cena ativa. |
| `godot_input_action` | `--allow-input` | Pressiona uma acao explicitamente autorizada em mcp_for_godot/allowed_input_actions por ate 1000 ms e aguarda liberacao no mesmo run_id. Exige --allow-run e --allow-input, Play proprio e coletor opt-in. |
| `godot_instance_scene_checked` | `--allow-write` | Previa textual de subcena com SHA e revisao exige --allow-write; aplicar carrega/instancia recursos e exige tambem --allow-run. |
| `godot_list_files` | Read-only baseline | Lista recursos do projeto configurado, sem sair da raiz e sem incluir .godot. |
| `godot_live_evidence` | `--allow-capture` | Reune imagem, amostras antes/depois, eventos, metricas e resumo do grafo editado na mesma execucao; declara lacunas de frame e erro. Exige --allow-capture. |
| `godot_live_image` | `--allow-capture` | Captura sob demanda um viewport selecionado (raiz por padrao) do jogo conectado ao depurador, em PNG limitado. Exige --allow-capture; pode incluir conteudo privado da janela. |
| `godot_live_snapshot` | Read-only baseline | Le a ultima amostra de runtime publicada pelo depurador do editor; informa indisponibilidade e idade sem consultar o renderer sob demanda. |
| `godot_live_timeline` | Read-only baseline | Le eventos limitados do receptor do editor: amostras, mudancas observadas entre leituras, lacunas, backpressure e rejeicoes. Nao afirma causalidade nem inspeciona cada frame. |
| `godot_mesh_library_export` | `--allow-write`, `--allow-run` | Carrega cena 3D permitida, gera MeshLibrary em estágio e promove arquivo com hash/checkpoint. Carregar cena pode executar código; exige --allow-write, --allow-run e allow_scene_load=true. |
| `godot_mesh_library_preview` | Read-only baseline | Inspeciona textualmente uma cena 3D fechada para candidatos MeshInstance3D diretos; não carrega cena. |
| `godot_mesh_library_rollback` | `--allow-write` | Remove MeshLibrary criada somente se hash coincidir e nenhum consumidor em disco for encontrado. Exige --allow-write. |
| `godot_open_scene` | `--allow-write`, `--allow-run`, `--allow-legacy-write` | Atalho legado para abrir cena sem precondicoes; bloqueado por padrao. Pode carregar @tool e alterar selecao; exige --allow-write, --allow-run e --allow-legacy-write. |
| `godot_open_scene_checked` | `--allow-write` | Previa textual da abertura de cena com alvo e estado esperados exige --allow-write; aplicar carrega a cena e exige tambem --allow-run. |
| `godot_play_scene` | `--allow-run` | Solicita Play no editor conectado para cena atual, principal ou caminho do projeto. Exige --allow-run; Stop pertence apenas a esta instancia MCP. |
| `godot_project_info` | Read-only baseline | Resume configuracao e hash do project.godot fixado nesta instancia MCP. |
| `godot_project_log` | Read-only baseline | Le saida limitada com cursor do processo de jogo iniciado nesta instancia; inclui erros de script quando Godot os emite no stdout/stderr. |
| `godot_read_text` | Read-only baseline | Le um arquivo de texto permitido do projeto (ate 128 KiB). |
| `godot_redo` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Refaz apenas se a proxima acao da cena ativa tiver sido criada pelo MCP. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_remove_leaf` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Remove apenas um no folha pertencente a cena ativa, com Desfazer/Refazer. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_remove_leaf_checked` | `--allow-write` | Remove no folha da cena esperada com revisao do grafo e historico do editor. Exige --allow-write. |
| `godot_resource_uid` | Read-only baseline | Consulta UID conhecido pelo cache ResourceUID do editor para recurso existente no projeto; nao altera arquivos. |
| `godot_revert_created_scene` | `--allow-write` | Remove somente cena criada nesta sessao do plugin, inalterada pelo hash e fora do editor/jogo. Exige --allow-write. |
| `godot_run_project` | `--allow-run` | Inicia somente o projeto configurado em processo Godot proprio, com backend permitido e log limitado. Exige --allow-run. |
| `godot_save_scene` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Salva a cena ativa .tscn pelo editor. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_save_scene_as_checked` | `--allow-write` | Salva a cena editada em caminho novo sem sobrescrever, com revisao do grafo, previa e compensacao protegida por hash. Exige --allow-write. |
| `godot_save_scene_checked` | `--allow-write` | Salva cena com caminho, revisao de grafo e SHA do arquivo esperados. Exige --allow-write; nao fornece rollback do disco. |
| `godot_scene_tree` | Read-only baseline | Inspeciona os nos pertencentes a cena ativa no editor e propriedades selecionadas. |
| `godot_script_apply` | `--allow-write`, `--allow-run`, `--allow-script-write` | Valida script em projeto minimo descartavel, grava checkpoint e troca atomicamente apos revalidar SHA/editor. Exige --allow-write, --allow-run e --allow-script-write. |
| `godot_script_preview` | `--allow-write`, `--allow-script-write` | Previsualiza troca de um .gd com SHA esperado e diff. Recusa @tool, inicializacao estatica e dependencias carregadas no parse. Exige --allow-write e --allow-script-write. |
| `godot_script_rollback` | `--allow-write`, `--allow-script-write` | Restaura checkpoint persistido somente se SHA atual coincidir; verifica conteudo restaurado. Exige --allow-write e --allow-script-write. |
| `godot_set_property` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Altera uma propriedade permitida com Desfazer/Refazer. Vetores: [x,y]; cores: #RRGGBB ou #RRGGBBAA. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_set_property_checked` | `--allow-write` | Altera uma propriedade da cena editada apenas se cena, revisao de godot_scene_tree e valor atual ainda coincidirem; usa Desfazer/Refazer e exige --allow-write. |
| `godot_status` | Read-only baseline | Confere a conexao ao editor e informa a cena ativa do projeto configurado. |
| `godot_stop_project` | `--allow-run` | Encerra somente o processo de jogo iniciado por esta instancia MCP. Exige --allow-run. |
| `godot_stop_scene` | `--allow-run` | Para somente a execucao iniciada por esta instancia MCP. Exige --allow-run. |
| `godot_texture_import_apply` | `--allow-write`, `--allow-run` | Aplica previa PNG com checkpoint persistente e EditorFileSystem.reimport_files; pode executar plugins de importacao. Exige --allow-write e --allow-run. |
| `godot_texture_import_preview` | `--allow-write` | Previa ConfigFile de importacao PNG sem carregar recurso; exige --allow-write, hashes do PNG e sidecar e opcoes restritas. |
| `godot_texture_import_rollback` | `--allow-write`, `--allow-run` | Compensa opcoes do sidecar e reimporta cache sob hash e checkpoint; nao restaura cache byte a byte. Exige --allow-write e --allow-run. |
| `godot_tilemap_compose_checked` | `--allow-write` | Previa de TileMap 2D exige --allow-write e nao carrega recurso; aplicar carrega textura e exige tambem --allow-run. |
| `godot_uid_repair_apply` | `--allow-write` | Aplica prévia de UID em uma cena fechada, com lock/checkpoint/hash e troca atômica. Exige --allow-write. |
| `godot_uid_repair_preview` | Read-only baseline | Prévia textual de correção do UID de um recurso em uma cena .tscn fechada, com hashes de cena e recurso; consumidores dinâmicos não são observados. |
| `godot_uid_repair_rollback` | `--allow-write` | Restaura cena do checkpoint se hashes da cena e recurso ainda coincidirem. Exige --allow-write. |
| `godot_undo` | `--allow-write`, `--allow-legacy-write` | LEGADO sem precondicoes, bloqueado por padrao. Desfaz apenas se a ultima acao da cena ativa tiver sido criada pelo MCP. Exige --allow-write. Exige --allow-legacy-write. |
| `godot_validate` | `--allow-run` | Executa a Godot 4.7.2 headless: import/editor, runtime (30 quadros) ou script SceneTree em tests/. Retorna saida, erros e codigo. Exige --allow-run. |
| `godot_version` | Read-only baseline | Le a versao do binario Godot configurado, com timeout; nao inicia o editor. |

A visible tool may still return `unavailable` when its editor, runtime,
renderer, or native-hook dependency is absent. Visibility is permission
filtering, not a claim that the current environment can complete the call.
