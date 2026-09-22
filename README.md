# forever-restore

Keeps addon settings on the WoW Forever beta client (`_classic_beta_`) from being lost on `/reload`,
logout and restart.

## The problem

The Forever beta client writes each addon's SavedVariables file to `WTF\Account\<account>\` as
normal, but never loads it back. Every addon therefore starts each session as a fresh install: no
settings, profiles or collected data.

## How it works

The client leaves a saved-variable global alone if an addon's Lua code has already set it when the
addon loads. This project uses that:

1. `scripts/Sync-ForeverSavedVars.ps1` runs in the background on Windows and checks the saved files
   every 50 ms.
2. Whenever the client writes one, the script rebuilds two files in `Interface\AddOns\!ForeverRestore\`:
   - `Account.lua`: the account-wide saved files of **every installed addon**.
   - `Characters.lua`: every character's per-character saved files. Each character's block only runs
     for that character:
     ```lua
     local character = (string.gsub(UnitName("player") or "", " ", "-"))
     if character == "Firstname-Lastname" then
         ... that character's files ...
     end
     ```
     The WTF folder is named `<First>-<Last>`, and the in-game name is `<First> <Last>`.
3. The `!` in the folder name makes the client load `!ForeverRestore` before every other addon. By the
   time an addon loads, its globals already hold the last saved values.

No other addon's files are edited, so new addons are covered automatically and addon updates can't
break anything.

Each file is written to a temp name and then swapped in, so the game never reads a half-written file.
On a `/reload` the files are rebuilt about 40–150 ms after the client's write, and that has been fast
enough in testing. Each addon's data goes inside its own Lua function, so Lua's per-function size
limits apply to one addon at a time. Addon files over 1 MB have worked.

Tested on the Forever beta (September 2026):
- `!ForeverRestore` loaded first of 25 addons.
- A value it set survived the owning addon's load, even for an addon with `## LoadSavedVariablesFirst`.
- An addon setting survived `/reload`.
- A per-character profile switch survived `/reload`, and another character kept its own profile.

## What is covered

| Covered | Not covered |
|---|---|
| Account-wide saved files (`## SavedVariables:`) of every installed addon | Blizzard's own files (`Blizzard_*.lua`). Many Blizzard UI addons load before any user addon, so this method can't reach them reliably. |
| Per-character saved files (`## SavedVariablesPerCharacter:`, under `WTF\Account\<account>\<realm>\<character>\`) of every installed addon | Saved files of addons that are no longer installed. They are skipped. |
| | A character name found under two realm folders. The in-game check can't tell them apart, so both are skipped and the log says so. |

Many addons keep their settings in named **profiles** (AceDB-based addons, for example) stored in the
account-wide file. The per-character file only records which profile a character uses. A change to a
shared profile therefore shows up on every character using it. That is the addon's design, not a leak
between characters.

## Files

| File | What it does |
|---|---|
| `scripts/Sync-ForeverSavedVars.ps1` | The background watcher. Rebuilds `!ForeverRestore` and keeps backups. |
| `scripts/Install-ForeverSavedVarsTask.ps1` | Registers the watcher as a hidden scheduled task that starts at logon. `-Remove` uninstalls it. |
| `addon/!ForeverRestore/` | The addon that loads first. The watcher generates its `Account.lua` and `Characters.lua`. |

## Requirements

- Windows with Windows PowerShell 5.1 (built in).
- The Forever beta installed at `C:\Program Files (x86)\World of Warcraft\_classic_beta_`. If yours is
  elsewhere, change `$WowRoot` at the top of `Sync-ForeverSavedVars.ps1`.

## Install

1. Copy the `scripts` folder somewhere permanent, for example `%LOCALAPPDATA%\ForeverSavedVars\`. The
   scheduled task runs the script from wherever the installer is, so don't run it from a folder you
   will delete.
2. If you have more than one folder under `WTF\Account\` (other than `SavedVariables`), set
   `$AccountName` at the top of `Sync-ForeverSavedVars.ps1` to the one you play on. With only one, it
   is found automatically.
3. Copy `addon\!ForeverRestore` into `_classic_beta_\Interface\AddOns\`.
4. In PowerShell, from the `scripts` folder, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-ForeverSavedVarsTask.ps1
   ```
   It prints `Installed and started task 'Forever SavedVars Sync'`, then generates `Account.lua` and
   `Characters.lua` within a second.
5. **Fully restart the game.** The client only notices a new addon on a full restart, not on `/reload`.

## Checking it works

- Log: `%LOCALAPPDATA%\ForeverSavedVars\sync.log`. Each rebuild logs a line such as
  `Account.lua rebuilt: 15 addon file(s), 2,053,929 bytes, 50 ms after the newest saved write` or
  `Characters.lua rebuilt: 4 character(s), 18 addon file(s), 387,701 bytes, 107 ms after ...`.
  A `SKIPPED` or `ERROR` line names the file.
- In game: change a setting, `/reload`, and check it is still there.
- Task status: `Get-ScheduledTask -TaskName "Forever SavedVars Sync"`.

## Backups

`%LOCALAPPDATA%\ForeverSavedVars\savedvariables\` holds a copy of **every** SavedVariables file the
client writes, for every addon, account-wide (`Account\`) and per character (`<realm>\<character>\`),
including Blizzard's own. A new copy is made only when a file changes. The last 20 versions of each
file are kept, named `<file>-<yyyyMMdd-HHmmss-fff>.lua`. Backups are taken after the restore files are
rebuilt, one file every 50 ms, so a `/reload` that writes every file at once takes a second or two to
be fully backed up.

To roll back an addon:
1. Close the game.
2. Stop the task (`Stop-ScheduledTask -TaskName "Forever SavedVars Sync"`).
3. Copy the backup you want over the file in `WTF\Account\<account>\SavedVariables\` (or the
   character's folder).
4. Start the task again. It rebuilds the restore files from that file on its next check.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-ForeverSavedVarsTask.ps1 -Remove
```

Then delete `Interface\AddOns\!ForeverRestore` and restart the game.

## Limitations

- Editing a restore file by hand while the game is running does nothing: the client overwrites the
  saved file on the next `/reload` or logout, and the watcher rebuilds from that. Edit the
  SavedVariables file with the game closed instead.
- If the client ever wrote the saved files more slowly on `/reload`, the rebuild could finish after the
  client reads `Account.lua` or `Characters.lua`. That session would then load the previous save. The
  log's "ms after the newest saved write" figure is the thing to watch.
- If an addon also ships its own restore file for this problem, it loads after `!ForeverRestore` and
  wins. Make sure that file is kept current, or remove it.

## License

MIT. See [LICENSE](LICENSE).
