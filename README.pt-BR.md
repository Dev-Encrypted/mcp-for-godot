# MCP for Godot

[English](README.md) · [Arquitetura](docs/ARCHITECTURE.md) · [Segurança](docs/SECURITY-MODEL.md) · [Catálogo de ferramentas](docs/TOOLS.md)

MCP for Godot é uma ponte local para clientes de IA compatíveis com MCP
inspecionarem, executarem, observarem e modificarem com cuidado um projeto
Godot. A solução combina um servidor MCP stdio em Python com um addon opt-in do
editor.

A configuração padrão é somente leitura. Novas capacidades aparecem apenas
com flags explícitas. As mutações usam argumentos tipados, caminhos limitados
ao projeto, hashes ou revisões esperadas, cargas limitadas, auditoria e reversão
quando a operação consegue oferecê-la.

> **Prévia:** a versão 0.10.0 oferece 65 ferramentas no perfil completo e 20
> no perfil padrão. Algumas operações protegidas do editor dependem de hooks
> nativos opcionais que não fazem parte deste repositório público. O servidor
> informa essa ausência em vez de declarar suporte inexistente.

## Capacidades principais

- Inspeção de arquivos, editor, cenas, nós, recursos gráficos, dependências,
  importação e saída recente de processos.
- Observação opt-in de uma cena 2D em execução com snapshot vivo, linha do tempo,
  métricas, viewports e captura PNG sob demanda.
- Execução de validações headless e controle de processos iniciados pelo MCP.
- Alterações protegidas de cena, recurso, importação de textura e GDScript com
  as permissões correspondentes.
- Registro resumido de operações sem gravar tokens da ponte nem corpos de script.
- Compatibilidade com inicialização MCP `2025-11-25` e descoberta `2026-07-28`.

## Instalação rápida

```powershell
git clone https://github.com/Dev-Encrypted/mcp-for-godot.git
Set-Location mcp-for-godot
python -m venv .venv
.\.venv\Scripts\python -m pip install -e .
.\scripts\install-addon.ps1 -Project "C:\caminho\meu-jogo"
```

No Godot, habilite **MCP for Godot** em **Projeto > Configurações do
Projeto > Plugins**. Use os modelos em [`clients/`](clients/README.md) para
configurar Codex, Claude Code ou outro cliente stdio.

```powershell
mcp-for-godot --project "C:\caminho\meu-jogo" --godot "C:\caminho\Godot_v4.7.2-stable_win64_console.exe"
```

## Perfis de permissão

| Perfil | Flags | Ferramentas visíveis | Uso recomendado |
|---|---|---:|---|
| Somente leitura | nenhuma | 20 | Descoberta, cena e telemetria |
| Validação | `--allow-run` | 27 | Testes headless e processos gerenciados |
| Edição protegida | `--allow-write --allow-run` | 50 | Edições com pré-condições e transações |
| Protegido completo | adicionar `--allow-capture --allow-input --allow-script-write` | 58 | Imagem, input limitado e scripts |
| Legado | adicionar `--allow-legacy-write` | 65 | Migração e projetos descartáveis |

Mesmo visível, uma ferramenta pode retornar `unavailable` se o editor, jogo,
renderizador ou hook nativo necessário não estiver disponível.

## Segurança

A ponte escuta somente em `127.0.0.1`. O addon gera um token aleatório por
sessão em `.godot/ai_mcp/bridge.json`, e o servidor confirma que a ponte pertence
ao projeto configurado. Isso protege contra acesso de rede acidental, mas não
isola processos executados pelo mesmo usuário e com leitura do projeto.

Leia o [modelo de segurança](docs/SECURITY-MODEL.md) antes de habilitar escrita,
captura, entrada ou alteração de scripts. Use um processo MCP por projeto e
versione o jogo antes de autorizar mutações.

## Observação viva

O addon não instrumenta automaticamente as cenas. Anexe
`res://addons/mcp_for_godot/runtime_probe.gd` a um nó, de preferência chamado
`AIMonitor`, e execute a cena com o depurador do editor. A coleta limita
frequência, tamanho da árvore, viewports, texto e bytes por mensagem. Captura de
pixels exige `--allow-capture`.

## Compatibilidade real

O Godot oficial atende inspeção do projeto, ponte local, observação opt-in,
processos e APIs públicas compatíveis. Parser nativo de shader, histórico
protegido da cena e buffer nativo do depurador exigem hooks C++ opcionais e retornam
indisponibilidade estruturada no editor oficial. Veja [COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Testes

```powershell
python -m unittest discover -s tests -v
$env:GODOT_BIN = "C:\caminho\Godot_v4.7.2-stable_win64_console.exe"
python -m unittest discover -s tests -v
```

Os testes cobrem o contrato MCP, permissões, confinamento de caminhos,
transações, empacotamento do addon e, quando `GODOT_BIN` está definido, carga
real do plugin em modo headless. Teste headless não comprova correção visual,
custo em GPU nem compatibilidade com todos os drivers.

## Escopo público

Este repositório contém o servidor MCP e o addon do editor. Hooks nativos
opcionais ficam fora desta distribuição. O plano público e seus critérios de
avanço estão em [ROADMAP.md](docs/ROADMAP.md).

## Licença

O código original está sob [Apache License 2.0](LICENSE). Créditos e marcas do
Godot estão documentados em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
