<#
.SYNOPSIS
  Install or upgrade dbt-horizon on a Windows machine, in the deploy layout (docs/deploy.md).

.EXAMPLE
  install.ps1 -Version v0.8.0 -HomeDir C:\dbt-horizon

.DESCRIPTION
  Run as the service user. Re-run with another -Version to upgrade or roll back.
  Private repo: set $env:DBT_HORIZON_GIT_TOKEN (read-only token); it is not stored.
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$HomeDir = 'C:\dbt-horizon',
    [string]$Python = 'python',
    [string]$Repo = 'https://github.com/harikrishna1822/dbt-horizon.git'
)
$ErrorActionPreference = 'Stop'

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not installed (Git for Windows)' }
& $Python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
if ($LASTEXITCODE -ne 0) { throw "$Python must be Python 3.11 or newer (use -Python 'C:\Python312\python.exe')" }

$gitAuth = @()
if ($env:DBT_HORIZON_GIT_TOKEN) {
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:DBT_HORIZON_GIT_TOKEN"))
    $gitAuth = @('-c', "http.extraHeader=Authorization: Basic $basic")
}

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
$app = Join-Path $HomeDir 'app'
Write-Output "==> dbt-horizon $Version into $app"
if (Test-Path -LiteralPath (Join-Path $app '.git')) {
    Invoke-Native git ($gitAuth + @('-C', $app, 'fetch', '--quiet', '--tags', '--force', 'origin'))
} else {
    Invoke-Native git ($gitAuth + @('clone', '--quiet', $Repo, $app))
}
Invoke-Native git @('-C', $app, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--force', "refs/tags/$Version")

$venvPython = Join-Path $HomeDir 'venv\Scripts\python.exe'
Write-Output "==> Python environment $HomeDir\venv"
if (-not (Test-Path -LiteralPath $venvPython)) { Invoke-Native $Python @('-m', 'venv', (Join-Path $HomeDir 'venv')) }
Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '--upgrade', "$app[export]")

Write-Output '==> Folders'
foreach ($dir in 'configs', 'secrets', 'logs', 'locks', '.dbt_horizon') {
    New-Item -ItemType Directory -Force -Path (Join-Path $HomeDir $dir) | Out-Null
}
# secrets: this user (and SYSTEM / Administrators) only
$secrets = Join-Path $HomeDir 'secrets'
Invoke-Native icacls @($secrets, '/inheritance:r', '/grant:r', "${env:USERDOMAIN}\${env:USERNAME}:(OI)(CI)F",
    '/grant:r', '*S-1-5-18:(OI)(CI)F', '/grant:r', '*S-1-5-32-544:(OI)(CI)F') | Out-Null
$deployEnv = Join-Path $HomeDir 'deploy.env'
if (-not (Test-Path -LiteralPath $deployEnv)) {
    Copy-Item (Join-Path $app 'deploy\examples\deploy.env') $deployEnv
    Write-Output "    created $deployEnv"
}

$installed = & (Join-Path $HomeDir 'venv\Scripts\dbt-horizon.exe') version
Write-Output "==> Installed dbt-horizon $installed"
Write-Output @"

Next (docs/deploy.md):
  1. $HomeDir\venv\Scripts\dbt-horizon.exe init ... -o $HomeDir\configs\<name>.yml
     (or copy $app\deploy\examples\config.yml), with workspace_root: ../.dbt_horizon/<name>
  2. $HomeDir\secrets\<name>.env from $app\deploy\examples\secrets.env
  3. $app\deploy\windows\run.ps1 <name> --mode read
  4. As administrator: $app\deploy\windows\register-tasks.ps1 -Name <name> -At 02:00
"@
