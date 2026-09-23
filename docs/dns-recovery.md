# Emergency DNS recovery

Use this when website names stop resolving on the home LAN. The normal setup
advertises AdGuard Home at `192.168.1.124` as the only DNS server through router
DHCP. If AdGuard or the homeserver is unavailable, new lookups can fail even
while the internet connection works. Cached names may continue working briefly.

AdGuard normally forwards to Quad9 over HTTPS. If that upstream exchange fails,
it can use Cloudflare's malware-filtering HTTPS resolver at
`https://security.cloudflare-dns.com/dns-query`. Both paths remain inside
AdGuard, preserving its local filtering and LAN rewrites. The providers' malware
lists differ. Bootstrap DNS includes addresses from both providers, but only
resolves the encrypted resolvers' hostnames; it is not the query fallback.
This redundancy cannot help if AdGuard itself, the server, or the WAN is down.
Nix-supplied DNS settings take precedence over web UI settings at service start.
See [AdGuard fallback configuration](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration#configuration-file)
and [Cloudflare's resolver endpoints](https://developers.cloudflare.com/1.1.1.1/setup/).

Keep this guide available locally. You will need the router's LAN management
address and login for a household-wide fallback. Use the administrator's LAN
computer: the restricted gaming host can query DNS but cannot administer the
server. These steps cover LAN recovery; they do not repair an unavailable
WireGuard gateway for someone away from home.

## 1. Check the failure

In Windows PowerShell, inspect the connected Ethernet or Wi-Fi adapter. Record
its `InterfaceIndex`, DNS servers, and default gateway:

```powershell
Get-NetIPConfiguration
Get-DnsClientServerAddress
```

Query AdGuard directly, then the public resolver directly, then Windows's
configured resolver. `example.com` should return public A records; the private
`map.joshcaz.com` answer from AdGuard should be `192.168.1.124`.

```powershell
Resolve-DnsName example.com -Type A -Server 192.168.1.124 -DnsOnly -NoHostsFile
Resolve-DnsName map.joshcaz.com -Type A -Server 192.168.1.124 -DnsOnly -NoHostsFile
Resolve-DnsName example.com -Type A -Server 9.9.9.9 -DnsOnly -NoHostsFile
Resolve-DnsName example.com -Type A -DnsOnly -NoHostsFile
Test-NetConnection 192.168.1.124 -Port 22
```

| Result | Next step |
| --- | --- |
| Public DNS works; AdGuard queries fail | Use the temporary fallback below and inspect AdGuard/server reachability. |
| AdGuard's private answer works; its public lookup fails | Inspect AdGuard's upstream errors and the server's internet access. A local rewrite does not prove upstream DNS works. |
| Direct AdGuard queries work; Windows's normal lookup fails | Check the adapter's DNS settings and clear its cache. Inspect VPN, other active adapters, or browser secure DNS if results differ between applications. |
| Both DNS paths fail | Check access to the router by its management IP, Wi-Fi/Ethernet connectivity, and the router's WAN status. Public DNS may also be blocked; failure alone does not prove an ISP outage. |

A failed SSH test alone does not prove the server is off: LAN restrictions or
SSH itself may explain it. From the administrator's WSL shell, this command
keeps the managed `homeserver` SSH identity and overrides only its destination,
so it does not need hostname resolution:

```bash
ssh -o HostName=192.168.1.124 homeserver
```

Once connected, inspect the service and its recent errors:

```bash
systemctl status adguardhome.service --no-pager
sudo journalctl -u adguardhome.service -n 100 --no-pager
```

The administration UI is also reachable by IP at `http://192.168.1.124:3000`.
If a deployment or pre-deployment backup is running, let it finish before
intervening: the consistent backup briefly stops AdGuard. Otherwise, for a
stopped or stuck service, restart it once and repeat the DNS queries:

```bash
sudo systemctl restart adguardhome.service
```

If it fails again, use the logs to diagnose the cause while the client uses
fallback DNS. For deployment failures, consult [server updates](server-updates.md)
and the updater's rollback/status behavior before retrying the release.

## 2. Restore DNS on one Windows computer

Open **Windows PowerShell as administrator** on the affected LAN computer.
Select the connected physical adapter using its index from step 1. Save its
original IPv4 DNS addresses and whether DNS comes from DHCP or is static; the
`netsh` output records both. DHCP for the IP address does not necessarily mean
DNS is automatic.

```powershell
$dnsRecoveryIfIndex = [uint32](Read-Host "InterfaceIndex of the connected LAN adapter")
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex
netsh interface ipv4 show dnsservers name="$dnsRecoveryIfIndex" |
    Tee-Object -FilePath "$env:USERPROFILE\dns-recovery-before.txt"
```

Keep that file until recovery is complete; do not overwrite it with fallback
settings on a second attempt. Replace only this adapter's IPv4 DNS servers with
Quad9's public pair, which the server already uses for bootstrap DNS:

```powershell
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex -AddressFamily IPv4 |
    Set-DnsClientServerAddress -ServerAddresses @("9.9.9.9", "149.112.112.112")
ipconfig /flushdns
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex
Resolve-DnsName example.com -Type A -DnsOnly -NoHostsFile
```

Try an ordinary public website too. This static DNS override lasts until you
remove it, including across a reboot or DHCP renewal. It bypasses AdGuard's ad
filtering, query log, and private rewrites. Quad9 still applies its own threat
blocking. Private service names may now return the public WAN address and may
fail on the LAN; applications on an offline server remain unavailable.

If Windows still chooses another resolver, inspect other active adapters, VPN
DNS, and any IPv6 DNS configuration shown above. Disabling IPv6 on the NixOS
server does not establish the router's or Windows client's IPv6 configuration.

Run these changes in Windows, even when the symptom is in WSL. With DNS
tunneling, WSL uses Windows's DNS handling. If Windows works and WSL still fails,
inspect WSL's DNS configuration separately; editing `/etc/resolv.conf` does not
repair Windows DNS. Save work before any WSL restart.

## 3. Optional household-wide fallback

Use this for a longer server outage when other household devices need DNS:

1. Open the router's management page by its LAN IP. The adapter's default
   gateway is a useful starting point; confirm the actual management address.
2. Save the current **LAN DHCP DNS** settings locally. The documented normal
   values are primary `192.168.1.124`, secondary empty. Record any actual
   differences before editing.
3. Temporarily replace those advertised addresses with `9.9.9.9` and
   `149.112.112.112`, and apply. Router menu names vary. Changing only WAN DNS
   will not fix clients that still receive `192.168.1.124` directly through
   DHCP. If the router advertises itself as a DNS proxy, use its corresponding
   forwarding setting and verify what clients actually receive.
4. Renew the DHCP lease on each affected client, or reconnect its network.
   On Windows, use `ipconfig /renew "Wi-Fi"`, substituting the actual adapter
   name, then `ipconfig /flushdns`. Renew only DHCP-managed connections.
5. Inspect the client's DNS servers and repeat the normal public lookup from
   step 1. Devices with manual DNS need their own temporary change; keep track
   of every changed device so it can be restored.

The same filtering and private-name limitations apply throughout the household.
If the router advertises additional IPv6 DNS, account for that separately rather
than assuming the IPv4 DHCP edit controls all clients.

## 4. Return to AdGuard

First verify that direct queries to `192.168.1.124` resolve both `example.com`
and `map.joshcaz.com` correctly, using step 1. Then restore in this order:

1. If changed, restore the router's saved LAN DNS settings. For this setup that
   means primary `192.168.1.124`, secondary empty. Restore any DNS proxy or IPv6
   settings changed during fallback as well.
2. Restore every manually changed client. In the same administrator PowerShell
   session, use the appropriate command below. If opening a new session, select
   the adapter index again from step 1 before running it.

For an adapter that originally used **automatic/DHCP IPv4 DNS**:

```powershell
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex -AddressFamily IPv4 |
    Set-DnsClientServerAddress -ResetServerAddresses
```

For an adapter that originally used **manual IPv4 DNS**, restore the exact
addresses in `dns-recovery-before.txt`. For the normal single-AdGuard setting:

```powershell
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex -AddressFamily IPv4 |
    Set-DnsClientServerAddress -ServerAddresses @("192.168.1.124")
```

Renew DHCP-managed clients if the router's advertised DNS changed. Then flush
the cache and test the client's normal resolver, without a `-Server` override:

```powershell
ipconfig /flushdns
Get-DnsClientServerAddress -InterfaceIndex $dnsRecoveryIfIndex
Resolve-DnsName example.com -Type A -DnsOnly -NoHostsFile
Resolve-DnsName map.joshcaz.com -Type A -DnsOnly -NoHostsFile
```

The public lookup should succeed and the map lookup should return
`192.168.1.124`. In AdGuard's query log, confirm the client's new queries arrive
and verify a domain currently blocked by the configured filters is still
blocked. Recheck any browser with its own secure-DNS settings if it behaves
differently. Leave no temporary public DNS overrides behind. A permanent public
secondary can bypass private rewrites; a second local resolver with matching
policy is tracked separately in [#12](https://github.com/joshcazalas/caz.nix/issues/12).

## Validate the procedure

At a convenient time, exercise steps 1, 2, and 4 on one administrator computer
while AdGuard stays running. Confirm public resolution during fallback and
private answers plus filtering after restoration. This checks the client
procedure without interrupting the rest of the household. It does not prove a
full server-outage recovery or the router-wide procedure.

Record the date, Windows version, adapter type, which path was tested, and
pass/fail results in [#8](https://github.com/joshcazalas/caz.nix/issues/8). Keep
router credentials and raw network dumps out of the issue. Record any untested
paths explicitly; writing this guide does not establish a completed live drill.

Command references: [Windows DNS server overrides and DHCP reset](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress?view=windowsserver2025-ps),
[netsh interface inspection](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface),
[ipconfig renewal and cache clearing](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig),
[WSL DNS tunneling](https://learn.microsoft.com/en-us/windows/wsl/networking#dns-tunneling),
and [Quad9 resolver addresses](https://docs.quad9.net/services/).
