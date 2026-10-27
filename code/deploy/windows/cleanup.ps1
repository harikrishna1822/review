<#
.SYNOPSIS
  Remove old dbt-horizon workspaces and run logs on Windows (same as deploy/cleanup.sh).

.DESCRIPTION
  Settings in deploy.env (KEY=VALUE) or the environment: KEEP_WORKSPACE_DAYS (14), KEEP_LOG_DAYS (30),
  WORKSPACE_ROOT (<HomeDir>\.dbt_horizon). The repo cache (repos\) and read-mode outputs (outputs\) are kept.
#>
param([string]$HomeDir)
$ErrorActionPreference = 'Stop'
if (-not $HomeDir) { $HomeDir = if ($env:DBT_HORIZON_HOME) { $env:DBT_HORIZON_HOME } else { 'C:\dbt-horizon' } }

$settings = @{}
$deployEnv = Join-Path $HomeDir 'deploy.env'
if (Test-Path -LiteralPath $deployEnv) {
    foreach ($line in Get-Content -LiteralPath $deployEnv) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2].Trim('"', "'") }
    }
}
function Setting([string]$Key, [string]$Default) {
    $fromEnv = [Environment]::GetEnvironmentVariable($Key)
    if ($fromEnv) { return $fromEnv }
    if ($settings.ContainsKey($Key) -and $settings[$Key]) { return $settings[$Key] }
    return $Default
}
$keepWs = [int](Setting 'KEEP_WORKSPACE_DAYS' '14')
$keepLogs = [int](Setting 'KEEP_LOG_DAYS' '30')
$root = Setting 'WORKSPACE_ROOT' (Join-Path $HomeDir '.dbt_horizon')

$script:removed = 0
function Remove-Old([string]$Parent, [int]$Depth, [int]$Days) {
    if (-not (Test-Path -LiteralPath $Parent)) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    $dirs = @(Get-Item -LiteralPath $Parent)
    for ($i = 0; $i -lt $Depth; $i++) { $dirs = @($dirs | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Force }) }
    foreach ($dir in $dirs | Where-Object { $_.LastWriteTime -lt $cutoff }) {
        # \\?\ prefix: dbt workspaces can be deeper than MAX_PATH
        cmd /c rd /s /q "\\?\$($dir.FullName)"
        Write-Output "removed $($dir.FullName)"
        $script:removed++
    }
}

if (Test-Path -LiteralPath $root) {
    $workspaces = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 2 -Filter workspaces -Force)
    foreach ($ws in $workspaces) { Remove-Old $ws.FullName 2 $keepWs }
}
Remove-Old (Join-Path $HomeDir 'logs') 2 $keepLogs
Write-Output "cleanup done: $script:removed folder(s) removed"
