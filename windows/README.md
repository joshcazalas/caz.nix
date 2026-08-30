# Declarative Windows 11 bootstrap

Windows state is organized by capability rather than by physical machine.
Nothing in this public directory maps a profile, account, key, location, or
hardware description to a particular device.

This is intentionally a small bootstrap and drift check, not an attempt to
recreate NixOS on Windows. WinGet Configuration owns common applications and a
few explicit preferences. Nix and Home Manager own Ubuntu inside WSL.

## Profiles and capabilities

Profiles under [`profiles/`](profiles/) select capability documents under
[`capabilities/`](capabilities/). They are applied in declaration order.

| Profile | Capabilities | Scope |
| --- | --- | --- |
| `minimal` | `base` | Common applications |
| `gaming` | `base`, `gaming` | Common applications and game launchers |
| `workstation` | `base`, `development`, `gaming` | Development and gaming without UI preferences |
| `workstation-preferences` | `base`, `development`, `gaming`, `preferences` | The workstation profile plus optional UI and privacy choices |
| `game-stream-host` | `game-stream-host` | Focused Sunshine/WireGuard shared-console host with private-LAN streaming |
| `game-stream-client` | `game-stream-client` | Focused Moonlight/WireGuard independently keyed client role |

The capabilities are deliberately narrow:

- `base`: Terminal, browsers, Discord, and Spotify;
- `development`: user-scoped Windows VS Code and declared extensions;
- `gaming`: Steam, the EA app, Ubisoft Connect, and Prism Launcher;
- `preferences`: optional registry-backed UI and privacy choices;
- `game-stream-host`: Sunshine, official WireGuard, a narrow remote-client
  subnet, and direct streaming from the trusted Windows `Private` LAN only;
- `game-stream-client`: Moonlight, official WireGuard, an independently
  generated device key, and a route only to the host tunnel `/32`.

The two game-stream profiles deliberately do not inherit `base`: applying a
focused infrastructure role must not install browsers, chat, media, launchers,
or development tools. See [`../docs/game-streaming.md`](../docs/game-streaming.md)
for the rerunnable prepare/enroll/apply workflow, private input contract, and
manual ceremonies. Do not hand-author Windows WireGuard documents.

Profile names describe behavior only. Select one at apply time and do not
commit a mapping from profiles to physical machines. Keep `preferences` last
in any new profile so a preference changed by a Windows release cannot block
functional software installation.

Packages are presence-only declarations. WinGet installs an absent package
with normal hash verification, while each application's signed built-in
updater owns routine version updates. The profile does not use `useLatest` as
a convergence requirement.

## One-time prerequisites

Finish Windows Update and update **App Installer** from the Microsoft Store.
The bootstrap requires Windows 11, WinGet 1.11.430 or later, and a Windows
account that is itself a local administrator. On the first apply, the bootstrap
enables WinGet Configuration automatically; that one-time operation requires
Microsoft Store access.

WSL installation remains an explicit one-time Windows operation. From an
elevated PowerShell window, run:

```powershell
wsl.exe --install --no-distribution
```

Restart Windows if requested, then install and launch Ubuntu:

```powershell
wsl.exe --install -d Ubuntu
```

Create the Linux user expected by the Home Manager configuration and follow
[`../bootstrap/README.md`](../bootstrap/README.md). The Windows profile does
not enable optional Windows features, convert distributions, or manage
reboots.

## Apply or check a profile

The preferred entry point runs from WSL and keeps the repository, Git, and SSH
state on Linux. Windows PowerShell and WinGet still execute natively on Windows:

```bash
cd ~/develop/caz.nix
./bootstrap/windows.sh workstation
./bootstrap/windows.sh workstation --check
```

The launcher discovers the current distribution and repository path with
`wslpath`; it does not hard-code an Ubuntu version or require `git.exe`. Both
game-stream roles default to their deliberately LAN-only stage:

```bash
./bootstrap/windows.sh game-stream-host
./bootstrap/windows.sh game-stream-host --check
./bootstrap/windows.sh game-stream-client
./bootstrap/windows.sh game-stream-client --check
```

The host installs Sunshine and converges its private-LAN policy; the client
installs Moonlight and replaces the installer's unrestricted inbound rule with
a program-scoped private-LAN rule. The role capabilities also ensure the
official WireGuard package is present for the later fixed remote path, but
neither LAN stage creates or starts a tunnel. After the LAN pilot and explicit
enrollment, `--stage remote` selects the complete tunnel policy.

WinGet elevates only resources marked with `securityContext: elevated`, so
approve the Windows UAC prompt when it appears. Do not launch a separate
administrator terminal; keeping the original Windows identity preserves HKCU
and user-scoped application state.

The direct Windows PowerShell entry point remains a fallback:

```powershell
$repo = 'WINDOWS_PATH_REPORTED_BY_WSLPATH'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "$repo\bootstrap\windows.ps1" `
    -Profile workstation
```

The first apply installs the Visual C++ runtime if it is absent. WinGet itself
provisions its supported DSC v3 processor when needed. The repository does not
download, pin, or schema-translate a separate DSC installation.

From that same fallback session, check for drift without applying declared
packages, extensions, or registry values:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "$repo\bootstrap\windows.ps1" `
    -Profile workstation `
    -Check
```

Exit code `0` means the profile matches. Exit code `10` means drift or a
missing prerequisite was detected. A read-only check never provisions that
prerequisite; run the profile once without `-Check` first.

Inputs are copied to
`%LOCALAPPDATA%\caz.nix\windows\<profile>` before WinGet runs, so execution
does not depend on a live WSL UNC working directory. WinGet applies each
capability independently and is not transactional: if a later capability
fails, earlier successful changes remain. Review the output and safely rerun
the same profile after correcting the failure.

Removing a capability later stops managing that state; it does not uninstall
packages or restore previous registry values. This bootstrap deliberately does
not attempt automatic rollback.

## Optional preferences

The preferences capability keeps Windows customization separate from the
dependable package baseline. It includes taskbar, Explorer, Search, Start,
advertising ID, suggested-content, and device-wide Recall snapshot choices.
These are plain desired-state values, not compatibility scripts. Windows
updates may reset or retire UI-related registry values; remove a stale
preference instead of adding version-specific repair logic.

The undocumented classic-context-menu CLSID workaround is intentionally not
managed. The device-scoped `DisableAIDataAnalysis` policy disables Recall
snapshot saving without duplicating the setting in an access-controlled HKCU
Policies subtree. Preference changes may require a sign-out or restart.

## Optional terminal font

Font installation and Windows Terminal JSON editing are intentionally outside
the configuration. The Starship prompt works best when the Windows Terminal
profile uses a Nerd Font; install one manually and select it under **Terminal
Settings → Defaults → Appearance**. MesloLGL Nerd Font matches the Linux-side
prompt configuration, but the Windows bootstrap works without it.

## Exact taskbar pins

The preferred order is:

1. Chrome
2. File Explorer
3. Spotify
4. Steam
5. Windows Terminal
6. Discord

Exact pin ordering remains a one-time manual operation. The supported layout
policy is not available across every Windows edition, and undocumented
Taskband or shell-verb automation would be too brittle to maintain.

## Validation boundary

CI parses every PowerShell and JSON file, validates the profile graph and
maintenance guardrails, and asks the current WinGet release to parse and
resolve each capability. There is no parallel standalone DSC validator.

Static validation cannot prove installer, registry, UAC, Store, or application
behavior. Test an actual apply before merging meaningful capability changes.
Review local changes before every apply: WinGet Configuration and DSC resources
can install software and change Windows settings.
