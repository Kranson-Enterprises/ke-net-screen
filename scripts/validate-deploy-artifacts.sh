#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ROOT_DIR="$(get_repo_root "${BASH_SOURCE[0]}")"
DEPLOY_DIR_GLOB="$ROOT_DIR/ke-net-screen-build/deploy-*"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [deploy_dir]"
  exit 1
fi

DEPLOY_DIR="$(resolve_deploy_dir "$ROOT_DIR" "${1:-}")"

if [[ -z "${DEPLOY_DIR:-}" || ! -d "$DEPLOY_DIR" ]]; then
  echo "[fail] no deploy directory found"
  echo "       expected pattern: $DEPLOY_DIR_GLOB"
  exit 1
fi

echo "[check] deploy directory: $DEPLOY_DIR"

# Validate presence of core metadata emitted by the build pipeline.
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
