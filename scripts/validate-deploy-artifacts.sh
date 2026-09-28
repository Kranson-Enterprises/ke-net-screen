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
# rpi-image-gen >= v2.8.0-54 ("deploy: one basename per build") no longer places
# image.json or the per-partition sparse images at the top level: they are the
# payload of the IDP bundle (<image name>.idp.tar.zst), checked further down.
required_files=(
  deployed.json
  config.yaml.zst
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

# IDP bundle: must exist and carry image.json plus the partition payloads.
idp_bundles=("$DEPLOY_DIR"/*.idp.tar.zst)
if [[ ! -f "${idp_bundles[0]}" ]]; then
  echo "[fail] no IDP bundle (*.idp.tar.zst) found"
  exit 1
fi
if ! command -v zstd >/dev/null 2>&1; then
  echo "[warn] zstd not installed; skipping IDP bundle content check"
else
  idp_listing="$(zstd -dc "${idp_bundles[0]}" | tar -t 2>/dev/null || true)"
  for member in image.json boot.vfat.sparse root.ext4.sparse; do
    if ! grep -qx "$member" <<< "$idp_listing"; then
      echo "[fail] IDP bundle ${idp_bundles[0]##*/} lacks $member"
      exit 1
    fi
  done
fi

echo "[ok] required deploy artifacts are present"
ls -lh "$DEPLOY_DIR"
