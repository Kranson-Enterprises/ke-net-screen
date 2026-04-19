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

echo "[check] ssh hardening policy baseline"
SSH_POLICY_FILE="etc/ssh/sshd_config.d/local_network_only.conf"
grep -q '^AddressFamily inet$' "$SSH_POLICY_FILE"
grep -q '^ListenAddress IGconf_network_ipaddress$' "$SSH_POLICY_FILE"
grep -q '^PermitRootLogin no$' "$SSH_POLICY_FILE"
grep -q '^PasswordAuthentication no$' "$SSH_POLICY_FILE"
grep -q '^KbdInteractiveAuthentication no$' "$SSH_POLICY_FILE"
grep -q '^PubkeyAuthentication yes$' "$SSH_POLICY_FILE"
grep -q '^AuthenticationMethods publickey$' "$SSH_POLICY_FILE"

echo "[check] ssh hardening policy is wired into active layer"
grep -q 'local_network_only.conf' layer/ke-00-layer.yaml

LATEST_RENDERED_SSH_POLICY="$(ls -1dt ke-net-screen-build/chroot-*/filesystem/etc/ssh/sshd_config.d/local_network_only.conf 2>/dev/null | head -n1 || true)"
if [[ -n "$LATEST_RENDERED_SSH_POLICY" ]]; then
  echo "[check] rendered ssh policy placeholders"
  if grep -q 'IGconf_' "$LATEST_RENDERED_SSH_POLICY"; then
    echo "[fail] unresolved placeholder found in rendered ssh policy: $LATEST_RENDERED_SSH_POLICY"
    exit 1
  fi
fi

echo "[check] preflight"
if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
  ./ke-net-screen.sh --preflight
elif [[ -f .env ]]; then
  ./ke-net-screen.sh --preflight
else
  echo "[warn] PIHOLE_PASSWORD not set and .env missing; skipping preflight"
fi

echo "[ok] pre-release checks completed"
