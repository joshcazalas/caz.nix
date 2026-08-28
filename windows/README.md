# Declarative Windows 11 configuration

Windows state is organized by capability rather than by physical machine.
Nothing in this public directory maps a profile, account, key, location, or
hardware description to a particular device.

WinGet Configuration and DSC own Windows. Nix and Home Manager own Ubuntu
inside WSL, and Home Manager activation does not install or modify Windows
software.

## Profiles and capabilities

Profiles under [`profiles/`](profiles/) are small JSON declarations that select
capabilities under [`capabilities/`](capabilities/). The bootstrap validates the
profile, stages only those capability documents, validates all of them before
applying any, and applies them in declaration order.

| Profile | Capabilities | Intended scope |
| --- | --- | --- |
| `minimal` | `base` | Common applications and supported preferences |
| `gaming` | `base`, `gaming` | Common state plus game launchers |
| `workstation` | `base`, `development`, `gaming` | Complete development and gaming environment |
| `workstation-debloated` | `base`, `development`, `gaming`, `debloat` | Complete environment plus destructive Appx removal |

The profile names describe behavior only. Select a profile at apply time; do
not commit a mapping from profiles to physical machines. A future capability
such as `game-stream-host` can be added without exposing where it is used.

The capabilities currently declare:

- `base`: Terminal, browsers, Discord, Spotify, supported per-user Explorer,
  Start, Search, privacy preferences, Recall snapshot policy, and the pinned
  Terminal font;
- `development`: WSL 2, Ubuntu 24.04, packaged WSL updates, user-scoped Windows
  VS Code, and declared Windows-side extensions;
- `gaming`: Steam, the EA app, Ubisoft Connect, and Prism Launcher;
- `debloat`: an explicit all-user and provisioned-image desired-absent Appx
  list. This capability is intentionally absent from every non-debloated
  profile.

Most consumer applications use `useLatest: true`. This deliberately converges
to the current WinGet package rather than reproducing an old binary. Bootstrap
infrastructure has explicit minimum or rejected versions, and the font archive
and installed font files are checksum-pinned.

Spotify is intentionally declared as present without `useLatest`. Its WinGet
manifest uses an evergreen vendor URL whose bytes can change before the
community manifest receives the new hash. WinGet correctly refuses that stale
download. Once installed, Spotify's own signed updater manages its version;
the declaration still installs it when absent without weakening WinGet's hash
verification.

Chrome uses the stable consumer EXE package identity (`Google.Chrome.EXE`)
rather than the separately cataloged enterprise MSI identity. This lets WinGet
correlate an existing ordinary Chrome installation instead of treating it as a
missing package variant and unnecessarily invoking a second installer.

## Apply or check a profile

Run the entry point from an ordinary Windows PowerShell session. Do not start
PowerShell with **Run as administrator**: WinGet elevates only resources marked
with `securityContext: elevated`, preserving the current account for HKCU,
fonts, Terminal settings, and user-scoped applications. Machine-scoped package
resources are marked elevated according to their current WinGet manifests.

The current Windows account must itself be a member of local Administrators.
The bootstrap refuses an account that would need alternate administrator
credentials because that would apply per-user state to the wrong identity.

When the repository lives at the standard WSL path:

```powershell
$repo = '\\wsl.localhost\Ubuntu-24.04\home\joshcaz\develop\caz.nix'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\bootstrap\windows.ps1" -Profile workstation
```

Check for drift without applying the declared Windows state:

```powershell
$repo = '\\wsl.localhost\Ubuntu-24.04\home\joshcaz\develop\caz.nix'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\bootstrap\windows.ps1" -Profile workstation -Check
```

On a machine that does not yet have the bootstrap prerequisites, prepare and
validate the selected profile before running its first drift check:

```powershell
$repo = '\\wsl.localhost\Ubuntu-24.04\home\joshcaz\develop\caz.nix'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\bootstrap\windows.ps1" -Profile workstation -Prepare
```

The default is `-Profile workstation`. Inputs are staged under
`%LOCALAPPDATA%\caz.nix\windows\<profile>` so WinGet and DSC never depend on a
live WSL UNC working directory. `-Check` updates that staging copy but does not
apply the declared packages, registry values, fonts, extensions, or removals.
`-Prepare` may install the Microsoft Visual C++ runtime machine-wide and the
checksum-pinned stable Microsoft DSC package for the current user. It then
stages and validates every selected capability through both WinGet and DSC but
exits before WinGet tests or applies any declared state. `-Prepare` and `-Check`
cannot be combined.

## WSL and the required reboot

The `development` capability tests for Virtual Machine Platform through the
`vmcompute` service and checks that the exact `Ubuntu-24.04` distribution is
registered as WSL 2. If that exact distribution exists as WSL 1, applying the
capability converts it in place with `wsl --set-version`; that conversion can
take several minutes and temporarily needs free disk space. On a fresh Windows
installation it runs:

```text
wsl.exe --install --no-distribution
wsl.exe --install -d Ubuntu-24.04 --no-launch
```

Enabling Virtual Machine Platform normally requires a restart. The first apply
stops with an explicit restart message rather than forcing an unexpected
reboot. Restart Windows and run the same profile command again; completed
capabilities are idempotent, and the second run installs the distribution and
continues. Creating the initial Linux user remains interactive on first launch.

## Debloat safety boundary

[`debloat-appx.json`](debloat-appx.json) is an exact desired-absent list. The
local helper never downloads or executes a moving third-party script, rejects
duplicate or malformed entries, and refuses protected Store, WinGet, Terminal,
Xbox, and gaming-framework identifiers.

Applying `debloat` removes matching packages for installed users and from the
online provisioned image. That is machine-wide and has no automatic rollback.
Use a disposable system or restorable snapshot for the first test, review the
JSON before every change, and select a profile containing `debloat` only when
that destructive policy is intentional.

## Windows edition boundaries

The base capability does not declare policies that Windows 11 Home silently
ignores, including `DisableWindowsConsumerFeatures` and the ADMX-backed
`DisableSearchBoxSuggestions`. It also omits the legacy
`TurnOffWindowsCopilot` policy, for which Microsoft now recommends AppLocker on
supported managed editions. The optional debloat capability removes the
current consumer Copilot Appx package, but the base profile does not claim a
cross-edition Copilot enforcement guarantee.

Recall snapshot saving is disabled through the device-scoped
`DisableAIDataAnalysis` policy value. The device scope covers every user and
avoids a redundant write to the access-controlled per-user Policies subtree.
Changes to Recall policy require a restart before the feature reflects them.

Some Explorer and taskbar preferences require one sign-out or Explorer restart
before their UI reflects the registry state.

## Windows Terminal settings

The font helper accepts Terminal's JSON-with-comments format, removes comments
and trailing commas only for parsing, and creates a timestamped backup before
rewriting an existing file. If it must change the file, the rewritten JSON is
strict JSON and comments are not preserved; the backup retains the original.

The MesloLGL archive is pinned to Nerd Fonts 3.4.0. Desired-state checks verify
all four installed font files, their SHA-256 hashes, and their HKCU registration
rather than accepting any font with the same family name. If a destination
already has the declared hash, the helper preserves the file even when its
registration needs repair; this also avoids trying to overwrite a font that a
running application has memory-mapped.

## Exact taskbar pins

The desired order is:

1. Chrome
2. File Explorer
3. Spotify
4. Steam
5. Windows Terminal
6. Discord

Microsoft's supported Start/Taskbar layout policy is not available across every
supported Windows edition. Undocumented Taskband-binary and shell-verb scripts
are too brittle to claim declarative convergence. Exact pin ordering therefore
remains a one-time manual operation. Microsoft's current policy behavior is
documented at <https://learn.microsoft.com/windows/configuration/taskbar/pinned-apps>.

## Fresh-install sequence

The repository is public, so read-only bootstrap does not require a GitHub SSH
key. On a fresh Windows installation where WSL is not yet available:

1. Finish Windows OOBE and Windows Update.
2. Download a reviewed repository archive to a local Windows directory.
3. Apply `bootstrap\windows.ps1 -Profile workstation` from that directory.
4. If requested, restart Windows and run the identical command again.
5. Launch Ubuntu 24.04 once and create the expected WSL user.
6. Clone the repository inside WSL and follow
   [`../bootstrap/README.md`](../bootstrap/README.md) for Nix/Home Manager.
7. Sign in to third-party applications and select any existing game libraries.

SSH authentication is optional for public read access and useful only when the
checkout needs authenticated GitHub writes. Account credentials, game EULAs,
arbitrary game libraries, OEM drivers, firmware, and exact taskbar pins remain
outside this configuration.

## Validation and upstream constraints

CI parses every PowerShell file with Windows PowerShell 5.1, validates the JSON
profile graph, asks WinGet to parse and resolve every resource, and asks
Microsoft DSC to schema-validate every capability document. WinGet recognizes
DSC-v3 configuration version `0.3` by the exact raw 2023/08 schema URI. Stable
DSC 3.2.3 accepts that document model under its canonical bundled URI instead.
The shared validator therefore gives WinGet's `configure show` command the
unchanged deployable document and gives DSC only an ephemeral copy with the
schema URI normalized; that copy is deleted immediately and is never eligible
for apply or drift testing.

DSC's validation command exits successfully when it can report a result even
when that result contains `valid: false`, so the shared bootstrap/CI validator
parses its forced JSON output and requires the `valid` field to be Boolean true.
CI includes regression assertions for schema normalization and rejection of a
synthetic false result. A real apply still belongs on a disposable Windows
environment first because validation cannot prove installer, UI, registry,
reboot, or Appx behavior.

The wrapper installs Microsoft's signed DSC 3.2.3 bundle from the official
release with a pinned SHA-256 when that stable version is missing. This avoids
silently accepting an older or preview package while the WinGet community
source catches up. It also rejects the WinGet 1.29 builds before 1.29.280 that
contained a fixed DSC elevation bug. The remaining fresh-install prerequisite
behavior is tracked upstream at
<https://github.com/microsoft/winget-cli/issues/6085>.

Review local changes before every apply. Microsoft correctly warns that a
WinGet Configuration and its DSC resources can execute arbitrary code.
