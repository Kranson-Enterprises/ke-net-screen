#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[check] repo root: $ROOT_DIR"
cd "$ROOT_DIR"

echo "[check] bash syntax: ke-net-screen.sh"
bash -n ke-net-screen.sh

echo "[check] bash syntax: dns-health-check.sh"
bash -n home/scripts/monitoring/dns-health-check.sh

echo "[check] bash syntax: net-snapshot.sh, power-report.sh, collect-appliance-logs.sh, eeprom-update.sh"
bash -n home/scripts/monitoring/net-snapshot.sh
bash -n home/scripts/monitoring/power-report.sh
bash -n home/scripts/network/collect-appliance-logs.sh
bash -n home/scripts/firmware/eeprom-update.sh
bash -n home/scripts/pihole/wpad-block.sh
bash -n home/scripts/pihole/export-adlist.sh
bash -n home/scripts/pihole/import-adlist.sh
python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' home/scripts/pihole/import_adlists.py home/scripts/pihole/import_regex_deny.py home/scripts/pihole/export_adlists.py home/scripts/network/dns-battery.py

# The ke-monitor layer installs these from the repository; a missing file fails the build late.
echo "[check] monitoring units present"
for unit in net-snapshot.service net-snapshot.timer power-report.service power-report.timer; do
  test -f "etc/systemd/system/$unit" || { echo "[fail] missing etc/systemd/system/$unit"; exit 1; }
done

# The monitors must run in summary mode so journald gets one record per run (full report in /var/log).
echo "[check] monitor units use --journal-summary"
grep -q -- "--journal-summary" etc/systemd/system/net-snapshot.service
grep -q -- "--journal-summary" etc/systemd/system/power-report.service

# The monitor layer must exist and be pulled in by the root layer.
echo "[check] ke-monitor layer wired in"
test -f layer/ke-25-monitor.yaml
grep -q "^# X-Env-Layer-Requires: .*ke-monitor" layer/ke-00-layer.yaml
test -f home/scripts/network/collect-appliance-logs.sh

# Prevent shipping with an accidental hardcoded default password.
echo "[check] hardcoded Pi-hole password"
if grep -R --line-number "pihole setpassword Ch@ngeM3" layer; then
  echo "[fail] hardcoded Pi-hole password found"
  exit 1
fi

echo "[check] env template contract"
grep -q '^PIHOLE_PASSWORD=' .env.example
grep -q '^PIHOLE_REGEX_DENY=' .env.example
grep -q 'pihole_regex_deny: \$PIHOLE_REGEX_DENY' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-pihole_regex_deny' layer/ke-00-layer.yaml

# Since rpi-image-gen v2.8.0-88 the kernel command line is assembled from drop-ins; ours must exist
# and carry the governor the health check asserts.
echo "[check] kernel command-line drop-in"
grep -q 'cpufreq.default_governor=schedutil' layer/ke-03-knlcfg.d/for/linux-base/cmdline.d/60-ke-appliance

# Validate SSH policy baseline expected by this project.
echo "[check] ssh hardening policy baseline"
SSH_POLICY_FILE="etc/ssh/sshd_config.d/local_network_only.conf"
grep -q '^AddressFamily inet$' "$SSH_POLICY_FILE"
grep -q '^ListenAddress IGconf_network_ipaddress$' "$SSH_POLICY_FILE"
grep -q '^PermitRootLogin no$' "$SSH_POLICY_FILE"
grep -q '^PasswordAuthentication yes$' "$SSH_POLICY_FILE"
grep -q '^KbdInteractiveAuthentication no$' "$SSH_POLICY_FILE"
grep -q '^ChallengeResponseAuthentication no$' "$SSH_POLICY_FILE"
# Key-only mode is deliberately NOT enforced: password auth stays enabled
# because key-only settings caused remote-login failures that are not yet
# fully debugged. The pubkey directives remain present but commented in the
# policy file for reference; assert that state so drift is caught either way.
grep -q '^# PubkeyAuthentication yes$' "$SSH_POLICY_FILE"
grep -q '^# AuthenticationMethods publickey$' "$SSH_POLICY_FILE"

# Ensure layer wiring includes the hardened SSH drop-in.
echo "[check] ssh hardening policy is wired into active layer"
grep -q 'local_network_only.conf' layer/ke-00-layer.yaml

LATEST_RENDERED_SSH_POLICY="$(ls -1dt ke-net-screen-build/chroot-*/filesystem/etc/ssh/sshd_config.d/local_network_only.conf 2>/dev/null | head -n1 || true)"
if [[ -n "$LATEST_RENDERED_SSH_POLICY" ]]; then
  # Rendered policy should have all template placeholders resolved.
  echo "[check] rendered ssh policy placeholders"
  if grep -q 'IGconf_' "$LATEST_RENDERED_SSH_POLICY"; then
    echo "[fail] unresolved placeholder found in rendered ssh policy: $LATEST_RENDERED_SSH_POLICY"
    exit 1
  fi
fi

# Run the same host prerequisite gate used by the main build script.
echo "[check] preflight"
if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
  ./ke-net-screen.sh --preflight
elif [[ -f .env ]]; then
  ./ke-net-screen.sh --preflight
else
  echo "[warn] PIHOLE_PASSWORD not set and .env missing; skipping preflight"
fi

echo "[ok] pre-release checks completed"
