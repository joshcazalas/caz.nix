# Local access-code management

The optional `schlage_local` integration provides an administrator-only **Lock
codes** panel for the Schlage Encode Plus HomeKit Access Code service. It uses
an existing HomeKit Device Bluetooth pairing, including ESPHome Bluetooth
proxies. Add **Schlage Local Codes** under Settings > Devices & services after
installing the component and restarting HA. It does not initiate pairing.

The panel reads codes when opened. It supports local labels, temporary PIN
reveal, adding and removing codes, and reading or changing the lock's native
auto-lock timeout. Opening the panel does not change codes or settings. Device
selection, labels, credentials and timeout choices remain runtime state.

## Behavior and limits

- PINs are masked until explicitly revealed, then hidden after 20 seconds,
  when the window loses focus, or when navigating away.
- Writes refresh the lock state, check the displayed revision, issue one
  command, and read back the result. Ambiguous writes are never retried
  automatically. Refresh and test at the keypad before another attempt.
- Removing a code requires confirmation. To replace a PIN, add and test its
  replacement before removing the old code.
- The last successfully read list stays visible after an error, but edits
  and reveals are disabled until a fresh read succeeds.
- Native auto-lock uses HomeKit's Auto Security Timeout characteristic
  (`1A` under service `44`). The lock advertises its valid range; zero disables
  the feature. Saving compares the current value with the displayed value,
  writes once, and verifies it. No timeout is imposed by the integration.
- Native timed locking does not establish that the door is physically closed.
- Per-code entry history is unavailable. The management log records up to
  200 code-management or settings changes, not who entered through the door.
  It is local HA state and is not tamper-proof.

## Compatibility and data handling

The BLE adapter is version-gated to aiohomekit 4.0.0, as used by HA 2026.8.3.
It resolves the existing HomeKit connection for each operation and shares its
operation lock and encrypted session. The public aiohomekit write API discards
control-point responses, so the adapter uses private request methods with
Return Response enabled. Review and rerun compatibility tests when upgrading
HA or aiohomekit; unsupported dependency versions block access-code commands.

Code-list responses may contain only opaque identifiers. The component reads
those identifiers in batches of at most 20, checks returned identifier sets,
and validates PINs against the advertised limits. Unknown flags retain their
raw meaning as unknown; the UI does not infer enabled or scheduled status.
An incomplete acknowledgement establishes success only if a fresh read
exactly matches the requested change and preserves all other codes.

Every WebSocket command requires an HA administrator. PINs are processed in
backend memory and sent to the authorized browser only for explicit reveal.
They are not persisted in component storage, entities, recorder attributes,
service calls, automation traces or browser storage. Relevant WebSocket and
HAP debug log emitters are filtered to suppress plaintext payload logging.
Diagnostics expose only response field types and lengths, never raw payloads.

Names, opaque code identifiers and management events are stored in
`.storage/schlage_local`. Revision tokens use a random in-memory HMAC key so
that they do not expose guessable PIN hashes. These checks cannot make writes
atomic with another independent HomeKit controller. If codes are replaced
outside the integration, verify labels because a device can reuse identifiers.

Read-only code mounts make the implementation release-managed. They do not
protect the lock from a compromised HA administrator or server root account.
Keep device-specific diagnostics, screenshots, runtime state and credentials
out of Git and public issues.

## Validation

Fast deterministic checks are part of `checks.x86_64-linux.schlage-local`:

```bash
python3 -m unittest discover -s tests -p test_schlage_local.py -v
node --check home-assistant/custom_components/schlage_local/frontend/panel.js
```

Compatibility tests use Python 3.14 with `homeassistant==2026.8.3`,
`aiohomekit==4.0.0`, `python-otbr-api==2.10.0`, `pyroute2==0.9.6` and
`home-assistant-frontend==20260729.7`:

```bash
python tests/schlage_ha_compat.py -v
```

`node tests/schlage_panel.mjs` requires Playwright and Chromium. It checks
masking and expiry, delayed-response races, escaped labels, keyboard and focus
behavior, duplicate-submission prevention, error recovery, responsive layouts,
themes and reduced motion. All responses are mocked; tests never contact a lock.

For hardware validation, retain a working code and mechanical key. Test a new
code with the door open, confirm it works while HA/proxy is offline, then remove
a separate temporary code and verify it no longer works. Confirm normal HomeKit
controls and labels survive an HA restart. Enter PINs locally in the panel.
Do not reset or re-pair a lock to troubleshoot a rejected code-list response.

Protocol references:

- [HomeKit Access Code research](https://github.com/rednblkx/homekit-lock-access-code)
- [aiohomekit 4.0.0 BLE adapter](https://github.com/Jc2k/aiohomekit/blob/4.0.0/aiohomekit/controller/ble/pairing.py)
- [Apple HAP characteristic definitions](https://github.com/apple/HomeKitADK/blob/master/HAP/HAPCharacteristicTypes.h)
