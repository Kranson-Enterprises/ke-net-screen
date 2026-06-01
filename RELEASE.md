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

- Bash syntax in critical scripts (ke-net-screen.sh, dns-health-check.sh)
- No hardcoded Pi-hole password in layer definitions
- SSH hardening policy baseline (PasswordAuthentication yes, PermitRootLogin no, strong ciphers, public key auth)
- Environment template contract (.env.example contains PIHOLE_PASSWORD)
- Preflight prerequisites (commands, free disk, network)

Verify no hardcoded Pi-hole password remains:

```bash
grep -R --line-number "pihole setpassword Ch@ngeM3" layer || true
```

## 2. Build Artifacts

Build artifacts without flashing media:

```bash
# sudo password required for device actions
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
- CPU governor state (performance vs. powersave)
- Unbound cache hit/miss ratios

## 4. Validate Artifact Metadata

```bash
./scripts/validate-deploy-artifacts.sh
```

This validates all 10 required artifacts exist:

- `deployed.json` – Deployment metadata
- `config.yaml.zst` – Compressed config
- `image.json.zst` – Compressed image metadata
- `manifest.zst` – Compressed manifest
- `filesystem-*.sbom.zst` – Compressed software bill of materials
- `*.img.sparse.zst` – Compressed sparse image (bootable)
- `boot.vfat.sparse.zst` – Compressed boot partition
- `root.ext4.sparse.zst` – Compressed root filesystem

Confirm deploy metadata exists and checksums are recorded before release publication.

## 5. Tag and Publish

1. Update changelog notes in your release description.
2. Create and push an annotated tag:

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
- Use `--preflight` before every release build.
- Only flash to a device after explicit path verification.

## 9. Security and Performance Hardening Checkpoints

This release includes verified security and performance improvements:

**Security Enhancements:**

- SSH hardening policy enforces public key authentication, no root login, strong ciphers (ChaCha20-Poly1305, AES-GCM).
- Baseline validation checks SSH policy during pre-release gate.

**Performance Observability:**

- DNS health check now monitors kernel buffer tuning (`net.core.rmem_max`, `net.core.wmem_max`, `net.core.netdev_max_backlog`).
- CPU governor state is checked and logged.
- Unbound cache hit/miss and rate-limit counters are captured.
- These metrics help validate performance tuning is applied post-deployment.
