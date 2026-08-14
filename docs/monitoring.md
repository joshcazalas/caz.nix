# Monitoring and alerting

Prometheus collects metrics, Alertmanager delivers notifications by email and
Discord, and Grafana renders one provisioned dashboard. Every listener binds to
loopback and is reached through SSH local forwarding.

This replaced the Beszel hub. Beszel is a good tool and its NixOS module now
covers SMART, systemd, and temperatures, but its alert thresholds live in a
web UI backed by a SQLite database. Every other invariant in this repository is
reviewable code validated before it deploys, and alerting is the last thing that
should be configured by hand: a monitoring system that silently stops alerting
is worse than none at all. Prometheus rules are Nix, reviewed in a pull request,
and checked by `promtool` while the system builds.

## What is watched

| Concern | Signal |
| --- | --- |
| Service failure | `node_systemd_unit_state{state="failed"}` |
| Backup failure | the same rule, plus a staleness check on `minecraft-backup.timer` |
| Deployment failure | the same rule, plus staleness on `caz-release-updater.timer` |
| Disk space | free percentage, plus a 24-hour `predict_linear` forecast |
| Disk health | `smartctl` health, self-test errors, reallocated sectors, NVMe spare and endurance |
| Temperature | `node_hwmon_temp_celsius` and per-drive SMART temperature |
| Memory | available memory and OOM kills |
| Total host loss | the external dead man's switch below |

A failed backup, a failed deployment, and a crashed service all surface as a
failed systemd unit, so one rule covers all three. The timer staleness rules
exist because a unit that *never runs* never fails.

`smartd` still schedules the SMART self-tests. `smartctl_exporter` only reports
results, so without a schedule the health summary slowly stops describing the
actual surface of the disk.

## Required secrets

The build **fails closed** until these exist. `sops-nix` validates secret keys
while the system builds, so CI blocks rather than deploying a server whose
alerting cannot start.

```console
sops secrets/homeserver.yaml
```

Add a `monitoring` block alongside the existing `cloudflare` block:

```yaml
monitoring:
    alertEmailTo: you@example.com
    alertEmailFrom: you@example.com
    smtpUsername: you@example.com
    smtpPassword: an-app-password-not-your-account-password
    discordWebhookUrl: https://discord.com/api/webhooks/...
    healthcheckUrl: https://hc-ping.com/...
    grafanaAdminPassword: a-long-random-password
    grafanaSecretKey: a-long-random-string
```

Notes on each:

- **SMTP** defaults to `smtp.gmail.com:587`, set through
  `homelab.monitoring.smtpSmarthost`. Gmail requires an *app password*, which
  needs two-factor authentication on the account. Never use the account
  password. Change the smarthost option if you move providers.
- **The mailbox itself is a secret here**, not because an address is sensitive,
  but because this repository is public and there is no reason to publish it.
- **Discord** takes a channel webhook: Server Settings → Integrations →
  Webhooks. A webhook URL is a bearer credential; anyone holding it can post to
  that channel.
- **`grafanaSecretKey`** encrypts credentials inside Grafana's own database.
  NixOS 26.05 removed the shared default because a predictable key made that
  encryption meaningless. Generate with `openssl rand -base64 32`.

Both transports receive every alert. Email is the primary channel because it is
platform-agnostic and survives leaving Discord; Discord is faster to notice.
Losing one channel does not silence the other.

## The dead man's switch

Prometheus and Alertmanager run on the machine they watch. If the host dies,
the power fails, or the ISP drops, nothing on that machine can tell you. The
standard Prometheus answer is a `Watchdog` alert whose expression is `vector(1)`
so it always fires, delivered to an outside observer that alerts when the
notifications *stop*.

Create a check at <https://healthchecks.io> (the free tier is sufficient), set
its period to about 5 minutes and its grace period comfortably longer — 20
minutes is reasonable — and put the ping URL in `monitoring/healthcheckUrl`.
The `Watchdog` alert is routed only to that check and never to email or
Discord, so it costs nothing in noise.

`homelab.monitoring.deadManSwitch.pingInterval` must stay well below the grace
period configured on the check, or a perfectly healthy system will be reported
as dead.

### Test it, then keep testing it

An untested dead man's switch is worse than none, because it manufactures
confidence. After the first deployment:

```console
sudo systemctl stop alertmanager.service
```

Wait out the grace period and confirm the external check notifies you. Start it
again afterwards. Repeat this occasionally alongside the backup restore drills;
both answer the same question, which is whether the safety net is real.

## Reaching the dashboards

Nothing here listens on the LAN. Forward the ports over SSH:

```console
ssh -L 3001:127.0.0.1:3001 -L 9093:127.0.0.1:9093 -L 9095:127.0.0.1:9095 joshcaz@homeserver
```

- Grafana `http://127.0.0.1:3001` — log in as `admin` with
  `monitoring/grafanaAdminPassword`
- Alertmanager `http://127.0.0.1:9093` — current alerts and silences
- Prometheus `http://127.0.0.1:9095` — ad-hoc PromQL, and Status → Rules to see
  which rules are loaded and when they last evaluated

Grafana's port is 3001 because AdGuard Home already owns 3000. Prometheus runs
on 9095 rather than its usual 9090 because Auxide's private metrics listener
already uses 9090 on this host.

## Adding the Raspberry Pi as a peer

Once the Pi is a NixOS host running this same module, add its private address:

```nix
homelab.monitoring.peers = [ "10.0.0.20" ];
```

Each host then scrapes the other's exporters, and the Alertmanagers form a
gossip cluster that deduplicates notifications. Alertmanager clustering needs no
quorum, so as long as one instance survives with a working network path, the
notification still leaves the house. This is the ordinary Prometheus
high-availability topology, not a workaround.

Peer monitoring and the dead man's switch solve different problems and neither
replaces the other. Peers catch *uncorrelated* failure — one machine's power
supply, a kernel panic, a dead disk, a crashed service — and catch it in seconds
with useful detail. They cannot catch correlated failure, because two machines
on one circuit behind one router and one ISP all fail together. The notification
path is itself a shared failure domain: a surviving Pi that cannot reach the
internet knows the homeserver is dead and still cannot say so.

A UPS decouples the most common correlated failure, a brief power cut. It does
nothing for an ISP outage.

Note that opening the exporters to the peer means they stop being loopback-only,
which is a `network-policy.nix` change and deserves its own review.

## Changing thresholds

All of them are options on `homelab.monitoring`, so a threshold change is a
reviewable diff:

```nix
homelab.monitoring = {
  diskWarnPercent = 15;
  diskCriticalPercent = 7;
  temperatureWarnCelsius = 80;
  diskTemperatureWarnCelsius = 60;
  retentionTime = "90d";
  retentionSize = "8GB";
};
```

Retention is bounded by both time and size, whichever is reached first, because
the metrics database shares the root NVMe with every other service.

## How this is validated before it reaches the server

- `promtool` checks every alerting rule and the Prometheus configuration while
  the system builds, so an expression that could never fire fails CI.
- Alertmanager's configuration contains `envsubst` placeholders, so `amtool`
  cannot check it directly. The module instead builds a dummy-substituted copy
  and runs `amtool check-config` on that, pulled into the closure through
  `system.extraDependencies`. A malformed route or receiver fails CI rather
  than being discovered during an incident.
- Assertions require every listener to stay on loopback, forbid a Grafana
  password from the environment, and require the Alertmanager credentials to
  arrive through an environment file so no mailbox, webhook, or password
  reaches the Nix store.

## Primary references

- Prometheus alerting rules:
  <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Alertmanager configuration:
  <https://prometheus.io/docs/alerting/latest/configuration/>
- Alertmanager high availability:
  <https://prometheus.io/docs/alerting/latest/high_availability/>
- `smartctl_exporter`:
  <https://github.com/prometheus-community/smartctl_exporter>
- Healthchecks self-hosting, if you later move the check onto the Pi:
  <https://healthchecks.io/docs/self_hosted/>
