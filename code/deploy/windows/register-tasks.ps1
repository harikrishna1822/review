<#
.SYNOPSIS
  Register Windows Task Scheduler tasks for dbt-horizon (run as administrator).

.EXAMPLE
  register-tasks.ps1 -Name retail.prod -At 02:00
  register-tasks.ps1 -Cleanup

.DESCRIPTION
  -Name: a daily task "dbt-horizon <name>" running deploy\windows\run.ps1 <name> at -At.
  -Cleanup: a weekly task "dbt-horizon cleanup" (Sunday 04:00) running cleanup.ps1.
  Tasks run as -User (default: the current user) whether or not it is logged on (S4U, no password
  stored). A run still going when the next one is due is not started twice (MultipleInstances IgnoreNew).
#>
param(
    [string]$Name,
    [string]$At = '02:00',
    [switch]$Cleanup,
    [string]$HomeDir = $(if ($env:DBT_HORIZON_HOME) { $env:DBT_HORIZON_HOME } else { 'C:\dbt-horizon' }),
    [string]$User = "$env:USERDOMAIN\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'
if (-not $Name -and -not $Cleanup) { throw 'give -Name <deployment> and/or -Cleanup' }
if ($Name -and $Name -notmatch '^[A-Za-z0-9._-]+$') { throw "invalid deployment name: $Name" }

$scripts = Join-Path $HomeDir 'app\deploy\windows'
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

function Register([string]$TaskName, [string]$Script, [string]$ScriptArgs, $Trigger) {
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`" $ScriptArgs -HomeDir `"$HomeDir`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $HomeDir
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\dbt-horizon\' -Action $action -Trigger $Trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Output "registered \dbt-horizon\$TaskName"
}

if ($Name) {
    Register "dbt-horizon $Name" (Join-Path $scripts 'run.ps1') $Name (New-ScheduledTaskTrigger -Daily -At $At)
}
if ($Cleanup) {
    Register 'dbt-horizon cleanup' (Join-Path $scripts 'cleanup.ps1') '' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00')
}
Write-Output "Run now: Start-ScheduledTask -TaskPath '\dbt-horizon\' -TaskName 'dbt-horizon $Name'"
