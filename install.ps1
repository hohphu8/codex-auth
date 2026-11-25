param([switch]$NoPath)

$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot 'windows\codex-auth.ps1'
if (-not (Test-Path -LiteralPath $tool)) {
    throw "Missing Windows codex-auth files next to install.ps1."
}

$arguments = @('install-user')
if ($NoPath) { $arguments += '--no-path' }
& $tool @arguments

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Warning 'Codex CLI was not found. Install it before using codex-auth.'
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning 'Node.js was not found. The verify and session commands need it.'
}
