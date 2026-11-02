# Container image pins

Each service's `Dockerfile` is a single `FROM registry/image:tag@sha256:digest`
instruction. These files are the source of truth for image references:
Dependabot's Docker updater reads and rewrites them, and `default.nix` reads
the same references into the NixOS OCI container configuration.

The files are not built during deployment. Container startup, mounts, networks,
and environment settings remain in the existing NixOS modules. Keep these
manifests limited to the single digest-pinned `FROM` instruction; Nix evaluation
rejects extra instructions and mutable references.

Dependabot proposes updates for review. Preserve the Minecraft Java tag suffix
unless a Java migration is intended, and review HA release notes and integration
compatibility. The image update does not change separately pinned Minecraft or
Paper versions. Check the upstream registry and platform availability before
merging an image update; evaluation alone does not pull or start it.
