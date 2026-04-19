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

Verify no hardcoded Pi-hole password remains:

```bash
grep -R --line-number "pihole setpassword Ch@ngeM3" layer || true
```

## 2. Build Artifacts

Build artifacts without flashing media:

```bash
./ke-net-screen.sh --build-only
```

Expected output root:

- `ke-net-screen-build/`

Important deploy metadata:

- `ke-net-screen-build/deploy-*/deployed.json`
- `ke-net-screen-build/deploy-*/config.yaml.zst`

## 3. Validate Artifact Metadata

```bash
./scripts/validate-deploy-artifacts.sh
```

Confirm deploy metadata exists before release publication.

## 4. Tag and Publish

1. Update changelog notes in your release description.
2. Create and push an annotated tag:

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

3. Publish release notes and attach build metadata and image artifacts from local build output.

## 5. Rollback

If a release is bad:

1. Rebuild and redeploy from a previous known-good tag.
2. Restore router DNS settings if needed.
3. Reflash SD using the previously validated image.

## 6. Secrets and Safety

- Never commit `.env`.
- Set `PIHOLE_PASSWORD` in `.env` before build.
- Treat built images as sensitive until first boot completes because the initial Pi-hole password is present in a one-time boot-partition secret file.
- Use `--preflight` before every release build.
- Only flash to a device after explicit path verification.
