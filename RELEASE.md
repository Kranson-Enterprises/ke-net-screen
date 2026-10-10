# Release Process

This project uses a lightweight manual release process while CI jobs remain disabled.

## One-Shot Local Preparation

Run the full local release preparation flow (checks, build-only, artifact validation) in one command:

```bash
./scripts/release-local.sh
```

## 1. Pre-Release Checks

Run local checks before tagging:

```bash
./scripts/pre-release-check.sh
```

This validates:

- Bash syntax in critical scripts (ke-net-screen.sh, dns-health-check.sh, net-snapshot.sh, power-report.sh, collect-appliance-logs.sh)
- Monitor units pass `--journal-summary` (one journald record per run; full reports in /var/log)
- Monitoring unit files present for the layer to install (net-snapshot and power-report service + timer)
- No hardcoded Pi-hole password in layer definitions
- SSH hardening policy baseline (password and public-key auth both accepted, no root login, no keyboard-interactive, strong ciphers/KEX/MACs; key-only mode is deliberately not enforced — see the commented directives in the policy file)
- Environment template contract (.env.example contains PIHOLE_PASSWORD)
- Preflight prerequisites (commands, free disk, network)

Verify no hardcoded Pi-hole password remains:

```bash
grep -R --line-number "pihole setpassword Ch@ngeM3" layer || true
```

## 2. Build Artifacts

Build artifacts without flashing media:

```bash
# runs rootless; sudo is only a last-resort cleanup fallback
./ke-net-screen.sh --build-only
```

Expected output root:

- `ke-net-screen-build/`

Important deploy metadata:

- `ke-net-screen-build/deploy-*/deployed.json`
- `ke-net-screen-build/deploy-*/config.yaml.zst`

## 3. Performance and Observability Baseline

After build-only, verify performance tuning is in place by checking health monitoring:

```bash
# Dry-run: check if performance observability functions exist
grep -q "check_sysctl_min\|check_cpu_governor\|check_unbound_cache_stats" home/scripts/monitoring/dns-health-check.sh && echo "Performance checks installed"
```

Key metrics to establish baseline post-deployment:

- Kernel buffer sizes (`net.core.rmem_max`, `net.core.wmem_max`)
- CPU governor state (expected: `schedutil`, set via `cpufreq.default_governor=` in the kernel command-line drop-in `layer/ke-03-knlcfg.d/for/linux-base/cmdline.d/60-ke-appliance`)
- Unbound recursions per day next to FTL's 24 h cached/forwarded split (a hit ratio is structurally ~0 % behind FTL)

## 4. Validate Artifact Metadata

```bash
./scripts/validate-deploy-artifacts.sh
```

This checks the newest `ke-net-screen-build/deploy-*/` directory for:

- Required named files: `deployed.json`, `config.yaml.zst`, `manifest.zst`
- At least one compressed image artifact (`*.img.zst`)
- At least one compressed SBOM (`*.sbom.zst`)
- The IDP bundle `<image name>.idp.tar.zst`, containing `image.json`,
  `boot.vfat.sparse` and `root.ext4.sparse`

Since rpi-image-gen v2.8.0-54 ("deploy: one basename per build, one hook per
concern") every deliverable is named after `image.name`: `<name>.img.zst` is the
classic whole-disk image and `<name>.idp.tar.zst` the provisioning bundle. The
per-partition sparse images and `image.json` are no longer deployed as separate
top-level files, and `SOURCE_DATE_EPOCH` is recorded alongside for reproducible
builds.

Note: after a `--source-unbound` build, the SBOM's `unbound` entry is rewritten
with the real source version and VCS reference
(`scripts/patch-sbom-source-unbound.sh`), and `deployed.json` is refreshed so
the recorded size/sha1 still match.

Confirm deploy metadata exists and checksums are recorded before release publication.

## 5. Tag and Publish

1. Update changelog notes in your release description.
2. Commit submodule pin updates so the tag records the exact build inputs
   (`rpi-image-gen`, `vendors/pi-hole`, `vendors/unbound`) — the working tree,
   including submodule pointers, should be clean before tagging.
3. Create and push an annotated tag:

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

1. Publish release notes and attach build metadata and image artifacts from local build output.

## 6. Post-Merge Validation (before tag)

After merging all workstream branches to main, validate merged state:

```bash
# Verify merged branches are now in main
git log --oneline --decorate -n 10

# Re-run pre-release checks on merged main
PIHOLE_PASSWORD='Ch@ngeM3' bash scripts/pre-release-check.sh

# Rebuild and re-validate on merged state
PIHOLE_PASSWORD='Ch@ngeM3' bash ke-net-screen.sh --build-only
bash scripts/validate-deploy-artifacts.sh
```

This ensures merge interactions did not introduce regressions.

## 7. Rollback

If a release is bad:

1. Rebuild and redeploy from a previous known-good tag.
2. Restore router DNS settings if needed.
3. Reflash SD using the previously validated image.

## 8. Secrets and Safety

- Never commit `.env`.
- Set `PIHOLE_PASSWORD` in `.env` before build (takes precedence over command line).
- If `.env` is not present, set via command line with leading space: `PIHOLE_PASSWORD='Ch@ngeM3' ./ke-net-screen.sh` to avoid shell history.
- Treat built images as sensitive until first boot completes because the initial Pi-hole password is present in a one-time boot-partition secret file.
- Treat build logs and `deploy-*/config.yaml.zst` as sensitive too: rpi-image-gen prints the resolved configuration (including the device password) into the build output, and the stored deploy config carries it as well. Do not share or upload either.
- Use `--preflight` before every release build.
- Only flash to a device after explicit path verification.

## 9. Security and Performance Hardening Checkpoints

This release includes verified security and performance improvements:

**Security Enhancements:**

- SSH hardening policy: no root login, LAN-only ListenAddress, strong ciphers (ChaCha20-Poly1305, AES-GCM). Password and public-key authentication are both accepted; key-only mode is deferred (see the commented directives in the policy file).
- Baseline validation checks SSH policy during pre-release gate.
- Source-built Unbound is protected from package-manager overwrite by local dpkg diversions, and the deploy SBOM is corrected to record the real source version.

**Performance Observability:**

- DNS health check now monitors kernel buffer tuning (`net.core.rmem_max`, `net.core.wmem_max`, `net.core.netdev_max_backlog`).
- CPU governor state is checked and logged.
- Unbound cache hit/miss and rate-limit counters are captured.
- These metrics help validate performance tuning is applied post-deployment.
