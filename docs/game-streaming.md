# Declarative private game streaming

The repository defines three reusable roles without assigning them to a
physical device:

- `game-stream-gateway`: a disabled-by-default NixOS WireGuard hub;
- `game-stream-host`: Sunshine, WireGuard, and narrow host security policy;
- `game-stream-client`: Moonlight, WireGuard, and narrow client routing policy.

Applying one of these roles is always explicit. Merely evaluating the flake or
checking out this repository does not run WinGet, install software, create an
account, open a port, or enroll a peer.

The declarative layer does not prove that a route is playable. Issue #63's
local, external, negative-access, performance, headless-display, session, and
revocation tests remain required before enabling the production gateway.

## Private input boundary

Never commit real addresses, endpoints, keys, peer mappings, account names, or
device names. The gateway consumes one SOPS value named
`gameStreamGatewayConfig`; Windows consumes a one-time local enrollment file.

The decrypted gateway value is an ordinary `wg-quick` document in this fixed
role order:

```ini
[Interface]
Address = GATEWAY_TUNNEL_IPV4/32
PrivateKey = GATEWAY_PRIVATE_KEY
ListenPort = 51820

# First peer is always the generic host role.
[Peer]
PublicKey = HOST_PUBLIC_KEY
AllowedIPs = HOST_TUNNEL_IPV4/32

# Second peer is always the generic client role.
[Peer]
PublicKey = CLIENT_PUBLIC_KEY
AllowedIPs = CLIENT_TUNNEL_IPV4/32
```

The runtime validator requires one gateway `/32`, exactly two distinct peer
`/32` routes, and the reviewed listener. It rejects `SaveConfig`, DNS/table
changes, and every `PreUp`/`PostUp`/`PreDown`/`PostDown` hook. The decrypted
file is rendered mode `0400` under `/run/secrets`; it never enters the Nix
store.

Edit the existing encrypted file with SOPS and add the multiline value:

```bash
nix develop
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
  sops secrets/homeserver.yaml
```

Only after the private input and router's single UDP forward are ready, enable
the gateway in a private deployment overlay or the host configuration:

```nix
homelab.gameStreamGateway = {
  enable = true;
  listenPort = 51820;
};
```

The gateway treats `wg-game` as untrusted before the broader RFC1918 policy.
It drops all tunnel traffic to the gateway and LAN. Forwarding permits only
the client role to reach the host role on TCP `47984`, `47989`, and `48010`
and UDP `47998-48000`, `48002`, and `48010`; the host may return only
established traffic. WireGuard's exact `AllowedIPs` rejects spoofed role
sources.

After deployment, this report prints counts and compliance categories without
printing keys, endpoints, addresses, or peer mappings:

```bash
sudo caz-game-stream-gateway report \
  /run/secrets/game-stream-gateway/config wg-game 51820
```

## Windows enrollment documents

Generate each Windows enrollment outside the repository. Each file must have:

- one interface IPv4 `/32` and private key;
- one gateway peer and endpoint;
- exactly one opposite-role IPv4 `/32` in `AllowedIPs`;
- `PersistentKeepalive = 25`;
- no default, LAN, DNS, table, save, or command-hook directive.

Review the source commit before applying. The host account named below is an
example role label, not a committed mapping; create the real dedicated
standard account manually and supply its local name only on the intended host.

```powershell
$commit = git rev-parse HEAD

# Intended host only. The input file is deleted after a successful DPAPI import.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-host `
  -GameStreamEnrollmentFile C:\private\game-stream-host.conf `
  -GameStreamRemoteAccount game-stream `
  -GameStreamRemotePlay Disabled `
  -SourceCommit $commit

# Intended Windows client only.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-client `
  -GameStreamEnrollmentFile C:\private\game-stream-client.conf `
  -SourceCommit $commit
```

The bootstrap copies every elevated payload into a restricted local staging
directory. WireGuard's manager converts the one-time plaintext enrollment into
its machine-protected `.conf.dpapi` format, deletes the staged plaintext, and
runs the official `WireGuardTunnel$game-stream` service. A failed apply retains
the caller's source file for recovery; secure it and rerun. A successful apply
deletes it. Once DPAPI enrollment exists, omit the enrollment argument on
later applies; replacement requires an explicit revocation first.

The host policy:

- rejects Sunshine versions below stable `2026.516.143833`;
- disables WireGuard Local System command hooks;
- sets Sunshine UPnP off, Web UI access to localhost, and IPv4-only binding;
- disables app notifications on the Windows lock screen for the whole device;
- disables installer-created or other broad Sunshine inbound rules;
- permits only the enrolled client `/32`, the `game-stream` interface, the
  Sunshine executable, and the exact streaming ports;
- requires the selected remote account to be enabled and belong only to the
  built-in Users group;
- rejects Sunshine applications that bypass its global session gate;
- keeps Sunshine disabled by default until the unattended policy is explicitly
  enabled.

After local credentials and pairing are complete, enable the unattended policy
once by reapplying the host role with the same account. The DPAPI tunnel is
reused; no plaintext enrollment file is needed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-host `
  -GameStreamRemoteAccount game-stream `
  -GameStreamRemotePlay Enabled `
  -SourceCommit $commit
```

`Enabled` does not mean that the primary desktop is continuously streamable.
It installs a SYSTEM session-arbiter task and a per-stream Sunshine gate. At
boot, logon, console switch, lock, and unlock, the arbiter reconciles Sunshine:

- no signed-in console user or a locked console: available;
- the selected remote account unlocked: available;
- any other account unlocked: stopped and unavailable;
- unknown session state or an arbiter error: stopped (fail closed).

Every Sunshine application also inherits a prep command that aborts launch
when a non-remote account is unlocked. Reapply with `-GameStreamRemotePlay
Disabled` to unregister the arbiter, remove its installed script, clear its
Sunshine prep command, disable the Sunshine service, and leave the WireGuard
tunnel enrolled for later reuse.

Check without installing, importing, or changing state:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\bootstrap\windows.ps1 `
  -Profile game-stream-host `
  -Check
```

Compliance output uses `compliant`, `drifted`, `manual ceremony required`, or
`environmental warning`. Reports include only the generic role and reviewed
source commit. They never print keys, endpoints, addresses, account names, or
peer mappings.

## Windows identity boundary

V1 selects one existing, dedicated local standard account for the remote-play
session. Its only local-group membership may be the built-in Users group. Do
not place personal credentials or secrets in its profile, and grant
game-library access only where the pilot proves it is needed. The role records
the account SID and reports drift if the account becomes disabled or gains
another local-group membership; it does not create the account, know a
person's identity, broaden filesystem ACLs, or change another user's files.

A separate Windows account is necessary but is not, by itself, a hard
Sunshine session boundary. Sunshine controls the active Windows console, and
Moonlight pairing is host-wide rather than tied to a Windows login. The
supported availability signal is therefore Windows session state, not an idle
timer: treat an unlocked primary session as active, and configure Windows to
lock normally when the owner is done. A remote player can connect when the
primary session is locked or signed out, select the dedicated account at the
Windows sign-in screen, and authenticate with that account's credentials.

Sunshine's Windows service follows the active console session, while Windows
reports lock/unlock and console-switch state through WTS and Task Scheduler.
The declarative arbiter stops Sunshine for an unlocked non-remote account; the
global prep command is a second check before Sunshine launches any stream.
Unlocking or switching to the primary account has priority and must disconnect
the remote stream. These mechanisms are based on the documented
[Sunshine service model](https://github.com/LizardByte/Sunshine/blob/master/tools/sunshinesvc.cpp),
[prep-command failure behavior](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html),
and Windows [session lock flags](https://learn.microsoft.com/windows/win32/api/wtsapi32/ns-wtsapi32-wtsinfoex_level1_w)
and [session-state task triggers](https://learn.microsoft.com/windows/win32/api/taskschd/ne-taskschd-task_session_state_change_type).

The pilot must still prove that connection startup, lock-screen capture, fast
user switching, unlock, sleep, and reboot never expose a frame from an unlocked
primary desktop. Until that passes, this is a fail-closed candidate design,
not a proven hard boundary. If Sunshine reconnects across a console switch or
shows the primary desktop before the arbiter stops it, use a dedicated VM or
physical host. Do not weaken the gate or expose RDP, WinRM, SMB, or Sunshine's
Web UI to make the shared-PC design work. The host role also enables Microsoft's
device policy to [suppress lock-screen app notifications](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-windowslogon#disablelockscreenappnotifications).

## Manual ceremonies and pilot-owned state

These remain deliberate manual steps:

- generating keys and private enrollment files;
- router UDP forwarding;
- creating the standard Windows session and local credentials;
- Sunshine Web UI credentials and Moonlight PIN pairing;
- game-account sign-in, MFA, and licenses;
- EDID/dummy-plug handling;
- configuring an ordinary Windows automatic-lock timeout appropriate for the
  primary user;
- recording tested power, display, reboot, lock, unlock, and session-switch
  behavior;
- two-step revocation: remove the WireGuard enrollment and Sunshine pairing.

Do not add declarative power/display or account ACL changes until the pilot has
shown exactly which settings are necessary.
