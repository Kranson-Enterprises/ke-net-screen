#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ROOT_DIR="$(get_repo_root "${BASH_SOURCE[0]}")"

cd "$ROOT_DIR"

info "local release wrapper started"
info "repo root: $ROOT_DIR"

if [[ -z "${PIHOLE_PASSWORD:-}" && ! -f "$ROOT_DIR/.env" ]]; then
  fail "PIHOLE_PASSWORD is not set and .env is missing. Set one before running."
fi

# Run static checks and policy checks before expensive build steps.
step "pre-release checks"
./scripts/pre-release-check.sh

# Build artifacts without flashing removable media.
step "build-only image generation"
if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
  PIHOLE_PASSWORD="$PIHOLE_PASSWORD" ./ke-net-screen.sh --build-only
else
  ./ke-net-screen.sh --build-only
fi

# Validate deploy metadata and required artifact set.
step "deploy artifact validation"
./scripts/validate-deploy-artifacts.sh

DEPLOY_DIR="$(resolve_deploy_dir "$ROOT_DIR")"
[[ -n "$DEPLOY_DIR" ]] || fail "Unable to resolve latest deploy directory"

echo ""
echo "Release-ready checklist"
echo "[x] pre-release checks passed"
echo "[x] build-only completed"
echo "[x] deploy artifacts validated"
echo "[x] latest deploy directory: $DEPLOY_DIR"
echo ""
echo "Next actions"
echo "1. Review deploy metadata: ls -lah $DEPLOY_DIR"
echo "2. Create tag: git tag -a vX.Y.Z -m \"Release vX.Y.Z\""
echo "3. Push tag: git push origin vX.Y.Z"
echo "4. Publish release notes and attach deploy artifacts"
