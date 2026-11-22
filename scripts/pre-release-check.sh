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
bash -n home/scripts/maintenance/ke-maintenance.sh
bash -n home/scripts/maintenance/schedule-reboot.sh
bash -n home/scripts/maintenance/verify-certs.sh
bash -n home/scripts/pihole/wpad-block.sh
bash -n home/scripts/pihole/export-adlist.sh
bash -n home/scripts/pihole/import-adlist.sh
python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' home/scripts/pihole/import_adlists.py home/scripts/pihole/import_regex_deny.py home/scripts/pihole/export_adlists.py home/scripts/network/dns-battery.py

# The ke-monitor layer installs these from the repository; a missing file fails the build late.
echo "[check] monitoring units present"
for unit in net-snapshot.service net-snapshot.timer power-report.service power-report.timer ke-maintenance.service ke-maintenance.timer; do
  test -f "etc/systemd/system/$unit" || { echo "[fail] missing etc/systemd/system/$unit"; exit 1; }
done

# The monitors must run in summary mode so journald gets one record per run (full report in /var/log).
echo "[check] monitor units use --journal-summary"
grep -q -- "--journal-summary" etc/systemd/system/net-snapshot.service
grep -q -- "--journal-summary" etc/systemd/system/power-report.service
grep -q -- "--journal-summary" etc/systemd/system/ke-maintenance.service

# Journald retention drop-in must ship, and the cron normalization must stay in first boot.
echo "[check] journald drop-in + cron single-scheduler normalization"
grep -q 'MaxRetentionSec=14month' etc/systemd/journald.conf.d/ke-journald.conf
grep -q 'ke-journald.conf' layer/ke-03-knlcfg.yaml
grep -q 'pihole updateGravity' layer/ke-15-piholecfg.yaml
grep -q 'ke-maintenance.timer' layer/ke-25-monitor.yaml
grep -q 'schedule-reboot.sh' layer/ke-25-monitor.yaml

# schedule-reboot.sh writes its units on the device at run time, so neither the build nor
# the rootfs check (validate-deploy-artifacts.sh) ever sees them. Render every cadence
# with --print and check what systemd would actually run:
#   - syntax: systemd-analyze verify; ANY output fails (an unknown key only warns, rc 0);
#   - specifiers: systemd expands %X in Description=/ExecStart= and ${VAR}/$$ in
#     ExecStart=, and verify accepts them all (%V is valid: /var/tmp) — the v0.3.7
#     bi-weekly bug. Outside comments only %% may appear; ExecStart= must be exactly
#     /bin/sh -c '<script>' with no ${ or $$;
#   - timer: OnCalendar parses and next fires at 05:10; Persistent=false (a catch-up
#     reboot timer can reboot-loop the box);
#   - behaviour: the script (%% -> %, as systemd does) runs under /bin/sh with a clean
#     environment, date pinned to real Sundays, logger/systemctl stubbed. Bi-weekly must
#     skip odd ISO weeks, reboot on even ones, and survive weeks 8 and 9 (a zero-padded
#     week is an invalid octal number in dash).
_sr_run() {   # unit-dir pinned-date tmp -> stub log in tmp/log, stderr in tmp/err
  local line script
  line=$(sed -n 's/^ExecStart=//p' "$1/ke-scheduled-reboot.service")
  line=${line//%%/%}
  script=${line#"/bin/sh -c '"}; script=${script%"'"}
  : > "$3/log"
  env -i PATH="$3/stub:/usr/bin:/bin" KE_FAKE_DATE="$2" KE_STUB_LOG="$3/log" \
    /bin/sh -c "$script" 2>"$3/err"
}
check_reboot_units() {   # path to schedule-reboot.sh; prints [fail] lines, returns 1 on any
  local sr=$1 tmp c d svc tmr out line desc cal when wk act exp have_sa=1
  local shape="^/bin/sh -c '[^']*'\$"
  local -a fails=()
  command -v systemd-analyze >/dev/null || { have_sa=0; echo "[warn] no systemd-analyze: unit verify and calendar checks skipped"; }
  tmp=$(mktemp -d) || return 1
  mkdir "$tmp/stub"
  printf '#!/bin/sh\nexec %s -d "$KE_FAKE_DATE" "$@"\n' "$(command -v date)" > "$tmp/stub/date"
  printf '#!/bin/sh\necho "logger $*" >> "$KE_STUB_LOG"\n' > "$tmp/stub/logger"
  printf '#!/bin/sh\necho "systemctl $*" >> "$KE_STUB_LOG"\n' > "$tmp/stub/systemctl"
  chmod +x "$tmp/stub/"*
  for c in 1 2 3 4 5 6; do
    d=$tmp/c$c; mkdir "$d"
    svc=$d/ke-scheduled-reboot.service; tmr=$d/ke-scheduled-reboot.timer
    if ! bash "$sr" --print "$c" "$d" >/dev/null 2>"$tmp/err" || [[ ! -s $svc || ! -s $tmr ]]; then
      fails+=("cadence $c: --print failed: $(head -1 "$tmp/err")"); continue
    fi
    if (( have_sa )); then
      out=$(systemd-analyze verify --man=no "$tmr" "$svc" 2>&1) && [[ -z $out ]] ||
        fails+=("cadence $c: systemd-analyze verify: $(head -1 <<<"$out")")
      cal=$(sed -n 's/^OnCalendar=//p' "$tmr")
      out=$(systemd-analyze calendar "$cal" 2>&1) && grep -q 'Next elapse: .* 05:10:00' <<<"$out" ||
        fails+=("cadence $c: OnCalendar '$cal' does not parse or does not fire at 05:10")
    fi
    grep -qx 'Persistent=false' "$tmr" || fails+=("cadence $c: timer lacks Persistent=false")
    out=$(grep -hv '^#' "$svc" "$tmr" | sed 's/%%//g' | grep '%' || true)
    [[ -z $out ]] || fails+=("cadence $c: single % (systemd specifier) in: $(head -1 <<<"$out")")
    line=$(sed -n 's/^ExecStart=//p' "$svc")
    [[ $line =~ $shape ]] || { fails+=("cadence $c: ExecStart is not /bin/sh -c '<script>'"); continue; }
    [[ $line != *'${'* && $line != *'$$'* ]] || fails+=("cadence $c: \${ or \$\$ in ExecStart (systemd substitutes it)")
    if [[ $c == 2 ]]; then
      # pinned Sunday : ISO week : expected action
      for when in "2026-11-22 05:10:47:skip" "2026-11-29 05:10:48:reboot" \
                  "2026-02-22 05:10:8:reboot" "2026-03-01 05:10:9:skip" "2027-01-03 05:10:53:skip"; do
        act=${when##*:}; when=${when%:*}; wk=${when##*:}; when=${when%:*}
        [[ $(date -d "$when" +%-V:%u) == "$wk:7" ]] || { fails+=("test data: $when is not a Sunday in ISO week $wk"); continue; }
        if [[ $act == reboot ]]; then
          exp=$(printf 'logger -t ke-scheduled-reboot bi-weekly reboot (ISO week %s)\nsystemctl reboot' "$wk")
        else
          exp="logger -t ke-scheduled-reboot odd ISO week $wk: skipping"
        fi
        if ! _sr_run "$d" "$when" "$tmp" || [[ -s $tmp/err ]] || [[ $(cat "$tmp/log") != "$exp" ]]; then
          fails+=("cadence 2, ISO week $wk: expected $act; got: $(tr '\n' ' ' < "$tmp/log")$(head -1 "$tmp/err")")
        fi
      done
    else
      desc=$(sed -n 's/^Description=Scheduled appliance reboot (\(.*\))$/\1/p' "$svc")
      exp=$(printf 'logger -t ke-scheduled-reboot scheduled reboot (%s)\nsystemctl reboot' "$desc")
      if [[ -z $desc ]] || ! _sr_run "$d" "2026-11-22 05:10" "$tmp" || [[ -s $tmp/err ]] || [[ $(cat "$tmp/log") != "$exp" ]]; then
        fails+=("cadence $c: expected one log line then a reboot; got: $(tr '\n' ' ' < "$tmp/log")$(head -1 "$tmp/err")")
      fi
    fi
  done
  rm -rf "$tmp"
  (( ${#fails[@]} == 0 )) && return 0
  printf '[fail] schedule-reboot: %s\n' "${fails[@]}"
  return 1
}
echo "[check] scheduled-reboot units (all six cadences): verify, specifiers, timer, behaviour"
check_reboot_units home/scripts/maintenance/schedule-reboot.sh || exit 1

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
grep -q '^UNBOUND_EXTRA_HARDENING=' .env.example
grep -q '^DOT_TERMINATOR=' .env.example
grep -q '^IMAGE_ROOT_PART_SIZE=' .env.example
grep -q '^KE_FLASH_DISCARD=' .env.example
grep -q 'dot_terminator: \$DOT_TERMINATOR' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-dot_terminator' layer/ke-00-layer.yaml
grep -q 'stunnel@dot' layer/ke-15-piholecfg.yaml
grep -q '^DOT_TLS_HARDENING=n$' .env.example
grep -q 'dot_tls_hardening: \$DOT_TLS_HARDENING' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-dot_tls_hardening:' layer/ke-00-layer.yaml
grep -q 'IGconf_ke_dot_tls_hardening' layer/ke-15-piholecfg.yaml
grep -q 'export DOT_TLS_HARDENING="${DOT_TLS_HARDENING:-n}"' ke-net-screen.sh
grep -qF 'curves = X25519MLKEM768:X25519:P-256:P-384' layer/ke-15-piholecfg.yaml   # ML-KEM first (stunnel's default list has none)
grep -qF 'ciphers = ECDHE+AESGCM:ECDHE+CHACHA20' layer/ke-15-piholecfg.yaml         # TLS 1.2 AEAD-only
grep -q '^UNBOUND_INCOMING_NUM_TCP=10$' .env.example
grep -q 'unbound_incoming_num_tcp: \$UNBOUND_INCOMING_NUM_TCP' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-unbound_incoming_num_tcp:' layer/ke-00-layer.yaml
grep -q 'IGconf_ke_unbound_incoming_num_tcp' layer/ke-10-unbcfg.yaml
grep -q 'export UNBOUND_INCOMING_NUM_TCP="${UNBOUND_INCOMING_NUM_TCP:-10}"' ke-net-screen.sh
grep -q '^SYSCTL_HARDENING=' .env.example
grep -q 'sysctl_hardening: \$SYSCTL_HARDENING' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-sysctl_hardening' layer/ke-00-layer.yaml
grep -q 'IGconf_ke_sysctl_hardening' layer/ke-03-knlcfg.yaml
grep -q 'SYSCTL_HARDENING' ke-net-screen.sh
grep -q '^net.ipv4.conf.all.accept_redirects = 0' etc/sysctl.d/60-net-observe.conf
# Per-interface patterns: without them eth0 keeps systemd's loose rp_filter (2) and the
# kernel's IPv6 accept_redirects (1) although "all"/"default" say otherwise.
grep -qxF 'net.ipv4.conf.*.rp_filter = 1' etc/sysctl.d/60-net-observe.conf
grep -qxF 'net.ipv6.conf.*.accept_redirects = 0' etc/sysctl.d/60-net-observe.conf
grep -q '^kernel.dmesg_restrict = 1' etc/sysctl.d/61-kernel-harden.conf
# One-file kernel toggles: ENV key, config key, layer declaration, hook, export, file.
for t in "SYSCTL_NO_TIOCSTI:62-ke-no-tiocsti.conf:dev.tty.legacy_tiocsti = 0" \
         "SYSCTL_NO_LDISC_AUTOLOAD:63-ke-no-ldisc-autoload.conf:dev.tty.ldisc_autoload = 0" \
         "SYSCTL_NO_IO_URING:64-ke-no-io-uring.conf:kernel.io_uring_disabled = 2"; do
  T=${t%%:*}; rest=${t#*:}; TF=${rest%%:*}; TL=${rest#*:}; t_lc=$(tr '[:upper:]' '[:lower:]' <<<"$T")
  grep -q "^$T=n\$" .env.example
  grep -q "$t_lc: \\\$$T\$" config/ke-net-screen.yaml
  grep -q "^# X-Env-Var-$t_lc:" layer/ke-00-layer.yaml
  grep -q "IGconf_ke_$t_lc" layer/ke-03-knlcfg.yaml
  grep -q "$TF" layer/ke-03-knlcfg.yaml
  grep -q "export $T=\"\${$T:-n}\"" ke-net-screen.sh
  grep -qxF "$TL" "etc/sysctl.d/$TF"
done
grep -q 'chmod 0440' layer/ke-25-monitor.yaml   # sudoers drop-in mode normalisation
grep -q 'stunnel-cert-watch.path' layer/ke-15-piholecfg.yaml
grep -q 'output = /var/log/stunnel-dot.log' layer/ke-15-piholecfg.yaml
grep -q 'logrotate.d/stunnel-dot' layer/ke-15-piholecfg.yaml
grep -q 'stunnel-dot.log' home/scripts/network/collect-appliance-logs.sh
grep -q 'setuid = stunnel4' layer/ke-15-piholecfg.yaml
grep -q 'stunnel4.service' layer/ke-15-piholecfg.yaml   # legacy sysv mask
grep -q 'sslVersionMin = TLSv1.2' layer/ke-15-piholecfg.yaml
grep -q 'tmpfiles.d/stunnel-dot.conf' layer/ke-15-piholecfg.yaml
grep -q 'foreground = quiet' layer/ke-15-piholecfg.yaml
grep -q 'stunnel-cert-guard.sh' layer/ke-15-piholecfg.yaml   # fingerprint guard on the cert watch
grep -q 'verify-certs.sh' layer/ke-25-monitor.yaml
grep -q 'enable-cache-dump.sh' layer/ke-25-monitor.yaml   # operator opt-in cache-dump grant
grep -q 'net.ipv4.tcp_fastopen = 3' etc/sysctl.d/99-unbound-tuning.conf   # server-mode TFO kernel pairing (answers unbound's configure WARNING)
grep -q -- '--extra-hardening' scripts/build-unbound.sh
grep -q 'UNBOUND_EXTRA_HARDENING' ke-net-screen.sh

echo "[check] unbound observability drop-in + anchored config check"
grep -q 'statistics-interval: 3600' etc/unbound/unbound.conf.d/ke-observability.conf
grep -q 'val-log-level: 1' etc/unbound/unbound.conf.d/ke-observability.conf
grep -q 'ke-observability.conf' layer/ke-10-unbcfg.yaml
grep -q 'auto-trust-anchor-file' scripts/build-unbound.sh
grep -q 'pihole_regex_deny: \$PIHOLE_REGEX_DENY' config/ke-net-screen.yaml
grep -q '^# X-Env-Var-pihole_regex_deny' layer/ke-00-layer.yaml

# Since rpi-image-gen v2.8.0-88 the kernel command line is assembled from drop-ins; ours must exist
# and carry the governor the health check asserts.
echo "[check] kernel command-line drop-in"
grep -q 'cpufreq.default_governor=schedutil' layer/ke-03-knlcfg.d/for/linux-base/cmdline.d/60-ke-appliance

# Since rpi-image-gen v2.9.0, config.txt is assembled from fragments too; ours must
# carry the appliance posture (wireless off, audio off, fan trips) or the stock
# fragments win and the image ships with radios enabled.
echo "[check] config.txt fragments"
CFRAG=layer/ke-03-knlcfg.d/for/rpi-boot-firmware/config.txt.d
grep -q 'dtoverlay=disable-wifi' "$CFRAG/50-ke-appliance"
grep -q 'dtoverlay=disable-bt' "$CFRAG/50-ke-appliance"
grep -q 'dtparam=audio=off' "$CFRAG/10-rpi-audio"
grep -q 'fan_temp0=45000' "$CFRAG/63-rpi-pi5"
test ! -f boot/firmware/config.txt

echo "[check] ntp single owner + timesync fallbacks + avahi self-heal"
grep -q '^NTP=' etc/systemd/timesyncd.conf.d/ke-timesync.conf
# IP literals must sit IN NTP= (timesyncd only consults FallbackNTP= when NTP= is
# empty), so time sync never waits for the local resolver at boot.
grep -qE '^NTP=.* 216\.239\.35\.[0-9]+' etc/systemd/timesyncd.conf.d/ke-timesync.conf
grep -qE 'active = false' etc/pihole/pihole.toml   # ntp.sync: timesyncd owns the clock
grep -q 'Restart=on-failure' etc/systemd/system/avahi-daemon.service.d/ke-restart.conf
grep -q 'ke-restart.conf' layer/ke-20-avhicfg.yaml

echo "[check] unattended security upgrades"
grep -q 'Unattended-Upgrade "1"' etc/apt/apt.conf.d/20auto-upgrades
grep -q 'Debian-Security' etc/apt/apt.conf.d/52ke-unattended-upgrades
grep -qF 'codename=${distro_codename}-updates' etc/apt/apt.conf.d/52ke-unattended-upgrades
grep -q 'unbound' etc/apt/apt.conf.d/52ke-unattended-upgrades
grep -q 'Automatic-Reboot "false"' etc/apt/apt.conf.d/52ke-unattended-upgrades
grep -q 'unattended-upgrades' layer/ke-03-knlcfg.yaml

echo "[check] eeprom harden subcommand"
grep -q -- '--harden' home/scripts/firmware/eeprom-update.sh
grep -q 'BOOT_ORDER=0xf1' home/scripts/firmware/eeprom-update.sh
grep -q -- '--unharden' home/scripts/firmware/eeprom-update.sh
# --unharden restores the Pi 5 default (0xf461 = SD, NVMe, USB; 0xf41 was the Pi 4 value)
grep -q 'BOOT_ORDER=0xf461' home/scripts/firmware/eeprom-update.sh

echo "[check] fan fields in the power trend record"
grep -q 'fan_state=%s fan_rpm=%s' home/scripts/monitoring/power-report.sh
grep -q 'gw_up=' home/scripts/monitoring/net-snapshot.sh
grep -q 'fan_state' home/scripts/network/collect-appliance-logs.sh
grep -q 'Deliberate Platform Decisions' CONFIG-OVERVIEW.md

# Validate SSH policy baseline expected by this project.
echo "[check] ssh hardening policy baseline"
SSH_POLICY_FILE="etc/ssh/sshd_config.d/local_network_only.conf"
grep -q '^AddressFamily inet$' "$SSH_POLICY_FILE"
grep -q '^ListenAddress IGconf_network_ipaddress$' "$SSH_POLICY_FILE"
grep -q '^PermitRootLogin no$' "$SSH_POLICY_FILE"
grep -q '^PasswordAuthentication yes$' "$SSH_POLICY_FILE"
grep -q '^KbdInteractiveAuthentication no$' "$SSH_POLICY_FILE"
grep -q '^ChallengeResponseAuthentication no$' "$SSH_POLICY_FILE"
# Post-quantum hybrid key exchange (ML-KEM and both sntrup761 spellings) stays offered;
# the validator's phase 2 runs sshd -t on the built image so a typo cannot ship.
grep -q '^KexAlgorithms mlkem768x25519-sha256,' "$SSH_POLICY_FILE"
grep -q '^KexAlgorithms .*,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,' "$SSH_POLICY_FILE"
# Key-only mode is deliberately NOT enforced: password auth stays enabled
# because key-only settings caused remote-login failures that are not yet
# fully debugged. The pubkey directives remain present but commented in the
# policy file for reference; assert that state so drift is caught either way.
grep -q '^# PubkeyAuthentication yes$' "$SSH_POLICY_FILE"
grep -q '^# AuthenticationMethods publickey$' "$SSH_POLICY_FILE"

# Ensure layer wiring includes the hardened SSH drop-in.
echo "[check] ssh hardening policy is wired into active layer"
grep -q 'local_network_only.conf' layer/ke-00-layer.yaml
# The rendered (built) ssh policy — placeholders resolved, ListenAddress set — is checked
# after the build by scripts/validate-deploy-artifacts.sh (phase 2, "B. SSH"); this script
# only checks the repository sources before the build.

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
