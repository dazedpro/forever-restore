# Keeps addon settings on the WoW Forever beta client from being lost.
#
# The Forever beta client writes SavedVariables but never loads them back. This watcher copies every
# installed addon's saved files into the !ForeverRestore addon, which loads before every other addon
# and defines the same globals, so each addon starts with its last saved values. It also keeps the
# last versions of every saved file as backups.
#
# Run hidden at logon (see Install-ForeverSavedVarsTask.ps1). Log: %LOCALAPPDATA%\ForeverSavedVars\sync.log

$ErrorActionPreference = "Stop"

$WowRoot = "C:\Program Files (x86)\World of Warcraft\_classic_beta_"
# The account folder under WTF\Account. Leave empty to use the only one there.
$AccountName = ""
$StateDir = Join-Path $env:LOCALAPPDATA "ForeverSavedVars"
$LogFile = Join-Path $StateDir "sync.log"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Write-Log([string]$Message) {
	Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message)
}

# Account folders hold a SavedVariables folder. WTF\Account\SavedVariables itself holds only the client's own files.
if (-not $AccountName) {
	$accounts = @([System.IO.Directory]::GetDirectories((Join-Path $WowRoot "WTF\Account")) |
		Where-Object { (Split-Path $_ -Leaf) -ne "SavedVariables" -and [System.IO.Directory]::Exists((Join-Path $_ "SavedVariables")) })
	if ($accounts.Count -ne 1) {
		Write-Log "ERROR: found $($accounts.Count) account folders under WTF\Account; set `$AccountName at the top of this script"
		exit 1
	}
	$AccountName = Split-Path $accounts[0] -Leaf
}
$AccountDir = Join-Path $WowRoot "WTF\Account\$AccountName"
$SavedDir = Join-Path $AccountDir "SavedVariables"

# Every SavedVariables file the client writes, account-wide and per character, is also kept as-is
$SavedBackupDir = Join-Path $StateDir "savedvariables"
$MaxSavedBackups = 20
# The "!" makes the client load !ForeverRestore before every other addon, so no addon's .toc needs editing
$RestoreAddonDir = Join-Path $WowRoot "Interface\AddOns\!ForeverRestore"
$AccountRestoreFile = Join-Path $RestoreAddonDir "Account.lua"
$CharacterRestoreFile = Join-Path $RestoreAddonDir "Characters.lua"


# Poll instead of using FileSystemWatcher: the client replaces the file (temp file + rename), and
# WaitForChanged missed that in testing. Polling a file's timestamp is cheap and cannot miss.
$PollMilliseconds = 50
function Get-SavedStamp([string]$Path) {
	if (-not [System.IO.File]::Exists($Path)) {
		return $null
	}
	$info = New-Object System.IO.FileInfo $Path
	return "{0}|{1}" -f $info.LastWriteTimeUtc.Ticks, $info.Length
}

# Lists every SavedVariables file, with the backup folder it belongs in: "Account" or "<realm>\<character>"
function Get-AllSavedFiles {
	$files = @()
	foreach ($path in [System.IO.Directory]::GetFiles($SavedDir, "*.lua")) {
		$files += @{ Path = $path; Scope = "Account" }
	}
	foreach ($realmDir in [System.IO.Directory]::GetDirectories($AccountDir)) {
		foreach ($characterDir in [System.IO.Directory]::GetDirectories($realmDir)) {
			$characterSavedDir = Join-Path $characterDir "SavedVariables"
			if (-not [System.IO.Directory]::Exists($characterSavedDir)) {
				continue
			}
			$scope = Join-Path (Split-Path $realmDir -Leaf) (Split-Path $characterDir -Leaf)
			foreach ($path in [System.IO.Directory]::GetFiles($characterSavedDir, "*.lua")) {
				$files += @{ Path = $path; Scope = $scope }
			}
		}
	}
	return $files
}

function Get-Sha256([byte[]]$Bytes) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString($sha.ComputeHash($Bytes))
	} finally {
		$sha.Dispose()
	}
}

# Copies a SavedVariables file into its backup folder, unless it matches the newest backup. Returns
# whether a copy was made. The client writes these files by rename, so a readable file is complete.
function Backup-SavedFile($File) {
	$name = [System.IO.Path]::GetFileNameWithoutExtension($File.Path)
	$dir = Join-Path $SavedBackupDir $File.Scope
	$bytes = $null
	for ($attempt = 1; $attempt -le 40 -and $null -eq $bytes; $attempt++) {
		try {
			$bytes = [System.IO.File]::ReadAllBytes($File.Path)
		} catch [System.IO.IOException] {
			Start-Sleep -Milliseconds 25
		}
	}
	if ($null -eq $bytes) {
		Write-Log "backup SKIPPED: $($File.Scope)\$name was unreadable"
		return $false
	}
	New-Item -ItemType Directory -Force -Path $dir | Out-Null
	$pattern = "^{0}-\d{{8}}-\d{{6}}-\d{{3}}\.lua$" -f [regex]::Escape($name)
	$existing = @(Get-ChildItem $dir -File | Where-Object { $_.Name -match $pattern } | Sort-Object Name -Descending)
	if ($existing.Count -gt 0 -and (Get-Sha256 $bytes) -eq (Get-Sha256 ([System.IO.File]::ReadAllBytes($existing[0].FullName)))) {
		return $false
	}
	$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
	[System.IO.File]::WriteAllBytes((Join-Path $dir "$name-$stamp.lua"), $bytes)
	$existing | Select-Object -Skip ($MaxSavedBackups - 1) | Remove-Item -Force
	return $true
}

# True for a saved file this watcher restores: not one of Blizzard's, and its addon is still installed
function Test-RestorableSavedFile([string]$Path) {
	$name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
	return (-not $name.StartsWith("Blizzard_")) -and [System.IO.Directory]::Exists((Join-Path $WowRoot "Interface\AddOns\$name"))
}

# The account-wide saved files to restore through !ForeverRestore
function Get-AccountRestoreFiles {
	return @([System.IO.Directory]::GetFiles($SavedDir, "*.lua") | Where-Object { Test-RestorableSavedFile $_ })
}

# The per-character saved files to restore, as path -> "<realm>\<character>" (from $savedFiles)
function Get-CharacterRestoreFiles {
	$files = @{}
	foreach ($file in $savedFiles) {
		if ($file.Scope -ne "Account" -and (Test-RestorableSavedFile $file.Path)) {
			$files[$file.Path] = $file.Scope
		}
	}
	return $files
}

# Reads a saved file, waiting while the client holds it open. The client writes by rename, so a
# readable file is complete.
function Read-WholeFile([string]$Path) {
	for ($attempt = 1; $attempt -le 40; $attempt++) {
		try {
			return [System.IO.File]::ReadAllText($Path)
		} catch [System.IO.IOException] {
			Start-Sleep -Milliseconds 25
		}
	}
	return $null
}

# Rereads each file in $Paths whose stamp changed into $Texts, and drops files no longer listed.
# Returns $null if nothing changed, otherwise the newest write time among the changed files.
function Update-TextCache($Paths, $Texts, $Stamps, [string]$Label) {
	$changed = $false
	$newestWrite = [DateTime]::MinValue
	foreach ($path in $Paths) {
		$stamp = Get-SavedStamp $path
		if (-not $stamp -or $stamp -eq $Stamps[$path]) {
			continue
		}
		$text = Read-WholeFile $path
		if ($null -eq $text) {
			Write-Log "$Label SKIPPED $(Split-Path $path -Leaf): unreadable"
			continue
		}
		$Texts[$path] = $text
		$Stamps[$path] = $stamp
		$changed = $true
		$writeTime = [System.IO.File]::GetLastWriteTimeUtc($path)
		if ($writeTime -gt $newestWrite) {
			$newestWrite = $writeTime
		}
	}
	foreach ($path in @($Texts.Keys)) {
		if ($Paths -notcontains $path) {
			$Texts.Remove($path)
			$Stamps.Remove($path)
			$changed = $true
		}
	}
	if (-not $changed) {
		return $null
	}
	return $newestWrite
}

function New-RestoreBuilder {
	$builder = New-Object System.Text.StringBuilder
	[void]$builder.Append("-- Generated by the forever-savedvars watcher. Do not edit: it is rewritten every time the client`r`n")
	[void]$builder.Append("-- saves. The Forever beta client does not restore SavedVariables, so this defines them at load.`r`n")
	return $builder
}

# Each saved file goes in its own function so Lua's per-function limits apply to one file at a time
function Add-RestoreBlock($Builder, [string]$Path, [string]$Text) {
	[void]$Builder.Append("`r`n-- $(Split-Path $Path -Leaf)`r`ndo`r`nlocal function restore()`r`n")
	[void]$Builder.Append($Text)
	[void]$Builder.Append("`r`nend`r`nrestore()`r`nend`r`n")
}

# Swaps the new contents in through a temp file so the game never reads a half-written file
function Write-RestoreFile([string]$File, $Builder, [string]$Summary, $NewestWrite) {
	$tempFile = "$File.tmp"
	[System.IO.File]::WriteAllText($tempFile, $Builder.ToString())
	Move-Item -Force $tempFile $File
	$lag = if ($NewestWrite -and $NewestWrite -gt [DateTime]::MinValue) { "{0:N0} ms after the newest saved write" -f ([DateTime]::UtcNow - $NewestWrite).TotalMilliseconds } else { "at startup or after a file was removed" }
	Write-Log ("{0} rebuilt: {1}, {2:N0} bytes, {3}" -f (Split-Path $File -Leaf), $Summary, $Builder.Length, $lag)
}

$accountTexts = @{}
$accountStamps = @{}
function Update-AccountRestore {
	$newestWrite = Update-TextCache $accountRestoreFiles $accountTexts $accountStamps "Account.lua"
	if ($null -eq $newestWrite -and [System.IO.File]::Exists($AccountRestoreFile)) {
		return
	}
	$builder = New-RestoreBuilder
	foreach ($path in ($accountTexts.Keys | Sort-Object)) {
		Add-RestoreBlock $builder $path $accountTexts[$path]
	}
	Write-RestoreFile $AccountRestoreFile $builder ("{0} addon file(s)" -f $accountTexts.Count) $newestWrite
}

# Characters.lua holds every character's files, each character's inside an "if" on the logged-in
# character's name. The WTF folder is "<First>-<Last>", the in-game name "<First> <Last>".
$characterTexts = @{}
$characterStamps = @{}
function Update-CharacterRestore {
	$newestWrite = Update-TextCache @($characterRestoreFiles.Keys) $characterTexts $characterStamps "Characters.lua"
	if ($null -eq $newestWrite -and [System.IO.File]::Exists($CharacterRestoreFile)) {
		return
	}
	$pathsByCharacter = @{}
	$realmsByCharacter = @{}
	foreach ($path in $characterTexts.Keys) {
		$scope = $characterRestoreFiles[$path]
		$character = Split-Path $scope -Leaf
		if (-not $pathsByCharacter.ContainsKey($character)) {
			$pathsByCharacter[$character] = @()
			$realmsByCharacter[$character] = @()
		}
		$pathsByCharacter[$character] += $path
		$realm = Split-Path $scope -Parent
		if ($realmsByCharacter[$character] -notcontains $realm) {
			$realmsByCharacter[$character] += $realm
		}
	}
	$builder = New-RestoreBuilder
	[void]$builder.Append("`r`nlocal character = (string.gsub(UnitName(`"player`") or `"`", `" `", `"-`"))`r`n")
	$numCharacters = 0
	foreach ($character in ($pathsByCharacter.Keys | Sort-Object)) {
		# The realm is not in the in-game name check, so the same name on two realms can't be told apart
		if ($realmsByCharacter[$character].Count -gt 1) {
			Write-Log "Characters.lua SKIPPED ${character}: found under more than one realm folder ($($realmsByCharacter[$character] -join ', '))"
			continue
		}
		$escaped = $character.Replace('\', '\\').Replace('"', '\"')
		[void]$builder.Append("`r`nif character == `"$escaped`" then`r`n")
		foreach ($path in ($pathsByCharacter[$character] | Sort-Object)) {
			Add-RestoreBlock $builder $path $characterTexts[$path]
		}
		[void]$builder.Append("end`r`n")
		$numCharacters++
	}
	Write-RestoreFile $CharacterRestoreFile $builder ("{0} character(s), {1} addon file(s)" -f $numCharacters, $characterTexts.Count) $newestWrite
}

Write-Log ("started for account folder {0}, polling every {1} ms" -f $AccountName, $PollMilliseconds)
$backupStamps = @{}
$savedFiles = @()
$accountRestoreFiles = @()
$characterRestoreFiles = @{}
$loop = 0
while ($true) {
	# The lists of saved files only change when a character or addon is added, so refresh them every 2 s
	if ($loop % 40 -eq 0) {
		try {
			$savedFiles = Get-AllSavedFiles
			$accountRestoreFiles = Get-AccountRestoreFiles
			$characterRestoreFiles = Get-CharacterRestoreFiles
		} catch {
			Write-Log "ERROR listing saved files: $($_.Exception.Message)"
		}
	}
	$loop++

	if ([System.IO.Directory]::Exists($RestoreAddonDir)) {
		try {
			Update-AccountRestore
		} catch {
			Write-Log "Account.lua ERROR: $($_.Exception.Message)"
		}
		try {
			Update-CharacterRestore
		} catch {
			Write-Log "Characters.lua ERROR: $($_.Exception.Message)"
		}
	}

	# Backups come last and take at most one file per loop, so a /reload that writes every saved file
	# at once never delays the restore files above by more than one backup
	foreach ($file in $savedFiles) {
		$stamp = Get-SavedStamp $file.Path
		if ($stamp -and $stamp -ne $backupStamps[$file.Path]) {
			# Record the stamp first, so a file that keeps failing is logged once per change, not every loop
			$backupStamps[$file.Path] = $stamp
			try {
				if (Backup-SavedFile $file) {
					Write-Log "backed up $($file.Scope)\$(Split-Path $file.Path -Leaf)"
				}
			} catch {
				Write-Log "backup ERROR $($file.Scope)\$(Split-Path $file.Path -Leaf): $($_.Exception.Message)"
			}
			break
		}
	}
	Start-Sleep -Milliseconds $PollMilliseconds
}
