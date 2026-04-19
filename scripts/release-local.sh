#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_GLOB="$ROOT_DIR/ke-net-screen-build/deploy-*"

step() {
  echo ""
  echo "[step] $1"
}

fail() {
  echo "[fail] $1"
  exit 1
}

cd "$ROOT_DIR"

echo "[info] local release wrapper started"
echo "[info] repo root: $ROOT_DIR"

if [[ -z "${PIHOLE_PASSWORD:-}" && ! -f "$ROOT_DIR/.env" ]]; then
  fail "PIHOLE_PASSWORD is not set and .env is missing. Set one before running."
fi

step "pre-release checks"
./scripts/pre-release-check.sh

step "build-only image generation"
if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
  PIHOLE_PASSWORD="$PIHOLE_PASSWORD" ./ke-net-screen.sh --build-only
else
  ./ke-net-screen.sh --build-only
fi

step "deploy artifact validation"
./scripts/validate-deploy-artifacts.sh

DEPLOY_DIR="$(ls -1dt $DEPLOY_GLOB 2>/dev/null | head -n1 || true)"
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
