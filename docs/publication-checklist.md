# Public launch checklist

Keep this checklist free of the old or replacement email address. Referring to
the privacy task generically preserves the purpose of doing it.

## Identity and history

- [ ] Choose a GitHub noreply address for commit authorship.
- [ ] Optionally create a personal-domain forwarding alias for public contact.
- [ ] Set the new address in local Git configuration for future commits.
- [ ] Replace the email metadata and SSH public-key comment in `settings.nix`.
- [ ] Create a local backup ref pointing to the original private history.
- [ ] Rewrite every commit author and committer address on a separate branch.
- [ ] Re-run Gitleaks against all rewritten history.
- [ ] Compare the rewritten tree with the intended source tree.
- [ ] Replace remote `main` with the reviewed history only when ready.

Do not merge a rewritten-history branch into the old `main`: a merge retains
both histories and therefore retains the old metadata. Publication day requires
replacing `main` with the reviewed rewritten lineage. Keep the backup ref local;
do not push it to the repository that will become public.

## Content review

- [ ] Confirm no plaintext sops files or private keys are tracked.
- [ ] Review domains, IP addresses, usernames, and service topology.
- [ ] Confirm every value in `settings.nix` is suitable for publication.
- [ ] Run `nix develop --command ./scripts/secret-scan.sh`.
- [ ] Run `nix develop --command ./scripts/check.sh`.
- [ ] Run `nix flake check --print-build-logs`.
- [ ] Decide on and add an open-source license, if desired.

## GitHub configuration

- [ ] Make the repository public.
- [ ] Apply the branch and security settings in `docs/ci-and-releases.md`.
- [ ] Confirm Dependabot opens both Nix and Actions update PRs.
- [ ] Make a harmless reviewed change to exercise the first public release.
- [ ] Download that release and verify `sha256sum --check SHA256SUMS`.
