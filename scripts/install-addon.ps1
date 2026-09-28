[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [System.IO.Path]::GetFullPath($Project)
$projectFile = Join-Path $projectRoot 'project.godot'
if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "The target does not contain project.godot: $projectRoot"
}

$source = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\addons\mcp_for_godot'))
$addonsRoot = Join-Path $projectRoot 'addons'
$target = Join-Path $addonsRoot 'mcp_for_godot'

if (Test-Path -LiteralPath $target) {
    if (-not $Force) {
        throw "The addon already exists at $target. Re-run with -Force to replace it."
    }
    $resolvedTarget = [System.IO.Path]::GetFullPath($target)
    $resolvedAddons = [System.IO.Path]::GetFullPath($addonsRoot) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTarget.StartsWith($resolvedAddons, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a path outside the project addons directory.'
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $addonsRoot | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Recurse
Write-Host "Installed MCP for Godot at $target"
Write-Host 'Enable it in Project > Project Settings > Plugins.'
