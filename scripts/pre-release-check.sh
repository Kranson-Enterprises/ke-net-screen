#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[check] repo root: $ROOT_DIR"
cd "$ROOT_DIR"

echo "[check] bash syntax: ke-net-screen.sh"
bash -n ke-net-screen.sh

echo "[check] bash syntax: dns-health-check.sh"
bash -n home/scripts/monitoring/dns-health-check.sh

echo "[check] hardcoded Pi-hole password"
if grep -R --line-number "pihole setpassword Ch@ngeM3" layer; then
  echo "[fail] hardcoded Pi-hole password found"
  exit 1
fi

echo "[check] env template contract"
grep -q '^PIHOLE_PASSWORD=' .env.example

echo "[check] preflight"
if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
  ./ke-net-screen.sh --preflight
elif [[ -f .env ]]; then
  ./ke-net-screen.sh --preflight
else
  echo "[warn] PIHOLE_PASSWORD not set and .env missing; skipping preflight"
fi

echo "[ok] pre-release checks completed"
