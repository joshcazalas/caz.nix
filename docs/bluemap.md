# BlueMap

[BlueMap](https://bluemap.bluecolored.de/) renders the Minecraft overworld into
3D web tiles. The plugin runs inside the existing Minecraft container, writes
static files, and Caddy serves them over HTTPS at `map.<domain>`.

## Before the first release that enables this

Two manual steps, same shape as the Minecraft exposure checklist. Do them
**before merging**, or Caddy will fail certificate issuance until they exist.

1. **Forward TCP 80 and 443** on the router to the homeserver's reserved LAN
   address. Certificate issuance needs both reachable from the Internet.
2. The `map.<domain>` A record is created automatically by Cloudflare DDNS on
   the next deployment. Leave it **DNS-only**, not proxied.

There is no third step for the plugin itself: the jar is pinned in the Nix
store and mounted into the container, so nothing is downloaded at startup.

## What it does and does not expose

The published site is **static files only** — no login, no upload path, no
server-side execution. That is a much smaller attack surface than Jellyfin,
which is why it is enabled while public Jellyfin remains off.

**Live player markers are deliberately disabled.** They would publish players'
usernames and in-world positions to anyone holding the URL. An assertion in
`modules/nixos/bluemap.nix` refuses the combination of public exposure and
player markers, so enabling them is a conscious decision that also requires
turning the map private, or getting everyone's agreement first.

Caddy's request log is discarded for this host. Static tiles carry no
credentials, but the log would still record who looks at the map and from
where.

## Disk

Rendered tiles are the dominant cost. `renderRadius` bounds a square around
spawn — the default 750 covers spawn and the built-up area around it while
skipping empty wilderness, which stores exactly as expensively as builds do.

Tiles live at `/var/lib/homelab/bluemap`, **outside** the Minecraft data
directory. That is deliberate: the daily backup archives the data directory
wholesale, and putting gigabytes of regenerable tiles inside it would bloat
every archive. Tiles are cache, not state — losing them costs CPU, not data.

Widening the radius later is safe. BlueMap re-renders the new area, and if you
narrow it, deletes the tiles that fall outside the new mask on its own.

```nix
homelab.bluemap.renderRadius = 1500;  # roughly 4x the area, and the disk
```

## Performance

Rendering runs off the Minecraft server thread, so it does not directly cost
tick rate. It does compete for CPU with everything else on the host.

- `renderThreads` (default 2 of 8 cores) caps how much CPU BlueMap may use.
- `playerRenderLimit` (default 3) pauses rendering while that many players are
  online. The map is never urgent; the game is. Set `-1` to render regardless.

The first full render is the expensive one and may take hours. Subsequent
updates are incremental.

## Operating it

BlueMap adds in-game commands for the server operator:

```text
/bluemap                 status and progress
/bluemap reload          reload configuration
/bluemap update          queue an update render
/bluemap fix-edges       clean up tile edges after changing the render mask
```

Watch progress from the shell:

```console
sudo docker logs --follow minecraft | grep -i bluemap
du -sh /var/lib/homelab/bluemap/web
```

## Configuration is release-controlled

Unlike the Minecraft whitelist, which is mutable server state, every BlueMap
setting here is policy: exposure, disk bounds, CPU budget, and privacy. All of
it is generated from Nix and mounted read-only into the container, so changing
it is a reviewed pull request rather than an edit on the server.

Two details worth knowing if you ever hand-edit these:

- The integrated webserver has **no bind-address option**. Enabling it listens
  on `0.0.0.0:8100`. It is switched off here and Caddy serves the files
  instead, so the host gains no extra listener. The firewall would drop 8100
  regardless, but there is no reason to open a second door.
- `client-decompression: true` in `webapp.conf` is **required** for static
  hosting. Tiles are stored gzip-compressed, and without it the browser
  receives compressed bytes it will not decode. BlueMap 5.23 added this option
  specifically for serving through an external web server.

Also note that the bounding key is `render-mask`. Several third-party guides
still reference `render-boundaries`, which this version ignores silently — the
map would render everything rather than failing loudly.

## Upgrading

Bump the version and hash together:

```console
nix store prefetch-file --hash-type sha256 \
  https://github.com/BlueMap-Minecraft/BlueMap/releases/download/v5.24/bluemap-5.24-paper.jar
```

Check the release notes for a required webapp refresh; BlueMap sometimes asks
you to delete `<webroot>/index.html` so it regenerates the viewer. Confirm the
new release still lists this server's Minecraft version on
[Hangar](https://hangar.papermc.io/Blue/BlueMap/versions) first.

## Primary references

- BlueMap wiki: <https://bluemap.bluecolored.de/wiki/>
- Render masks: <https://bluemap.bluecolored.de/wiki/customization/Masks.html>
- Releases: <https://github.com/BlueMap-Minecraft/BlueMap/releases>
