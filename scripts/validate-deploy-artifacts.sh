#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR_GLOB="$ROOT_DIR/ke-net-screen-build/deploy-*"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [deploy_dir]"
  exit 1
fi

if [[ $# -eq 1 ]]; then
  DEPLOY_DIR="$1"
else
  DEPLOY_DIR="$(ls -1dt $DEPLOY_DIR_GLOB 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${DEPLOY_DIR:-}" || ! -d "$DEPLOY_DIR" ]]; then
  echo "[fail] no deploy directory found"
  echo "       expected pattern: $DEPLOY_DIR_GLOB"
  exit 1
fi

echo "[check] deploy directory: $DEPLOY_DIR"

required_files=(
  deployed.json
  config.yaml.zst
  image.json.zst
  manifest.zst
)

for f in "${required_files[@]}"; do
  if [[ ! -f "$DEPLOY_DIR/$f" ]]; then
    echo "[fail] missing required file: $DEPLOY_DIR/$f"
    exit 1
  fi
done

if ! ls "$DEPLOY_DIR"/*.img.zst >/dev/null 2>&1; then
  echo "[fail] no compressed image artifact (*.img.zst) found"
  exit 1
fi

if ! ls "$DEPLOY_DIR"/*.sbom.zst >/dev/null 2>&1; then
  echo "[fail] no compressed SBOM artifact (*.sbom.zst) found"
  exit 1
fi

echo "[ok] required deploy artifacts are present"
ls -lh "$DEPLOY_DIR"
