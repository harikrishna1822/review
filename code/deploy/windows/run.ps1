<#
.SYNOPSIS
  dbt-horizon scheduled run on Windows: one deployment (config) per call, never two at once.

.EXAMPLE
  run.ps1 retail.prod --mode write

.DESCRIPTION
  Same as deploy/run.sh. Deploy layout under -HomeDir (default: $env:DBT_HORIZON_HOME, else C:\dbt-horizon):
    configs\<name>.yml, secrets\<name>.env, deploy.env, logs\<name>\<UTC time>\run.log, status.json, artifacts\
  Settings in deploy.env (KEY=VALUE): DBT_HORIZON_BIN, DBT_HORIZON_COMMAND, LOCK_NAME, NOTIFY_WEBHOOK, NOTIFY_ON.
  Exit code: dbt-horizon's (0 ok, 1 failed, 2 config error); 75 = skipped, the previous run of the same lock is still going.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Name,
    [string]$HomeDir,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$DbtHorizonArgs
)
$ErrorActionPreference = 'Stop'

if ($Name -notmatch '^[A-Za-z0-9._-]+$') { Write-Error "invalid deployment name: $Name (letters, digits, . _ -)"; exit 2 }
if (-not $HomeDir) { $HomeDir = if ($env:DBT_HORIZON_HOME) { $env:DBT_HORIZON_HOME } else { 'C:\dbt-horizon' } }

function Read-Settings([string]$Path) {
    $settings = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2].Trim('"', "'") }
        }
    }
    return $settings
}
$settings = Read-Settings (Join-Path $HomeDir 'deploy.env')
function Setting([string]$Key, [string]$Default) {
    $fromEnv = [Environment]::GetEnvironmentVariable($Key)
    if ($fromEnv) { return $fromEnv }
    if ($settings.ContainsKey($Key) -and $settings[$Key]) { return $settings[$Key] }
    return $Default
}
$bin = Setting 'DBT_HORIZON_BIN' (Join-Path $HomeDir 'venv\Scripts\dbt-horizon.exe')
$command = Setting 'DBT_HORIZON_COMMAND' 'run'
$lockName = Setting 'LOCK_NAME' $Name
$notifyOn = Setting 'NOTIFY_ON' 'failure'
$webhook = Setting 'NOTIFY_WEBHOOK' ''

$config = Join-Path $HomeDir "configs\$Name.yml"
$envFile = Join-Path $HomeDir "secrets\$Name.env"
if (-not (Test-Path -LiteralPath $config)) { Write-Error "config not found: $config"; exit 2 }

# --- lock: one run per lock name (released by Windows if the process dies) --------------
$mutex = New-Object System.Threading.Mutex($false, "Global\dbt-horizon-$lockName")
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { [Console]::Error.WriteLine("skipped: a run holding lock '$lockName' is still going"); exit 75 }

try {
    $started = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $runDir = Join-Path $HomeDir "logs\$Name\$started"
    if (Test-Path -LiteralPath $runDir) { $runDir = "$runDir-$PID" }    # two runs in one second
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $log = Join-Path $runDir 'run.log'

    $argv = @($command, '-c', $config)
    if (Test-Path -LiteralPath $envFile) { $argv += @('--env-file', $envFile) }
    if ($command -in @('run', 'analyze', 'export')) { $argv += @('--artifacts', (Join-Path $runDir 'artifacts')) }
    if ($DbtHorizonArgs) { $argv += $DbtHorizonArgs }

    function Log([string]$Line) { Write-Output $Line; Add-Content -LiteralPath $log -Value $Line -Encoding UTF8 }
    Log "dbt-horizon deploy: $Name, $command, started $started on $env:COMPUTERNAME"
    Log "command: $bin $($argv -join ' ')"

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ErrorActionPreference = 'Continue'          # stderr lines of the native command are not errors
    & $bin @argv 2>&1 | ForEach-Object { Log "$_" }
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 1 }
    $ErrorActionPreference = 'Stop'

    $finished = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    Log "finished $finished, exit code $code"
    $status = [ordered]@{ name = $Name; command = $command; started = $started; finished = $finished; exit_code = $code; log = $log } |
        ConvertTo-Json
    $utf8 = New-Object System.Text.UTF8Encoding($false)     # no BOM: JSON readers choke on it
    [IO.File]::WriteAllText((Join-Path $runDir 'status.json'), $status, $utf8)
    [IO.File]::WriteAllText((Join-Path $HomeDir "logs\$Name\last_status.json"), $status, $utf8)

    if ($webhook -and ($code -ne 0 -or $notifyOn -eq 'always')) {
        $result = if ($code -eq 0) { 'OK' } else { "FAILED (exit $code)" }
        $body = @{ text = "dbt-horizon $Name ($command) on ${env:COMPUTERNAME}: $result. Log: $log" } | ConvertTo-Json
        try { Invoke-RestMethod -Method Post -Uri $webhook -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null }
        catch { [Console]::Error.WriteLine("warning: notification to NOTIFY_WEBHOOK failed: $($_.Exception.Message)") }
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
exit $code
