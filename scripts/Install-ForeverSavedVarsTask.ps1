# Registers (or removes with -Remove) a scheduled task that runs Sync-ForeverSavedVars.ps1 hidden at
# logon for the current user, and starts it immediately.
param([switch]$Remove)

$ErrorActionPreference = "Stop"
$TaskName = "Forever SavedVars Sync"
$ScriptPath = Join-Path $PSScriptRoot "Sync-ForeverSavedVars.ps1"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
	Stop-ScheduledTask -TaskName $TaskName
	Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
if ($Remove) {
	Write-Output "Removed task '$TaskName'"
	return
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Output "Installed and started task '$TaskName'"
