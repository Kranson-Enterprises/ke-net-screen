#!/bin/bash
# validate-deploy-artifacts.sh — post-build validation of the latest build, in two phases:
#
#   1. Deploy artifacts: deployed.json, config.yaml.zst, manifest.zst, *.img.zst, *.sbom.zst
#      and the IDP bundle's image.json + partition payloads.
#   2. Rootfs contents, when the build's rootfs is still on disk: ~70 read-only checks of
#      what the image actually contains — build integrity, SSH, accounts and privilege,
#      file permissions, kernel/sysctl/modules, systemd units, service configuration,
#      private configuration and leak checks. Ownership is only visible inside the rootless
#      build namespace, so this phase re-runs the script under `podman unshare`.
#      Comparisons against the PRIVATE build sources (private/pihole.toml,
#      private/adlists_export.csv, .env.production) run only when those files exist;
#      secret values are never printed — only file names and counts.
#
# Usage:
#   scripts/validate-deploy-artifacts.sh [deploy_dir] [options]
#     --rootfs DIR        rootfs to check (default: newest ke-net-screen-build/chroot-*/filesystem)
#     --build-log FILE    also scan the build log for copy/missing-file and apt/dpkg errors
#     --artifacts-only    phase 1 only
#     --rootfs-only       phase 2 only
#
# Exit: 0 when nothing failed (warnings allowed), 1 on any failure, 2 on a usage error.
# Phase-2 lines are PASS / WARN / FAIL, followed by a "pass / warn / fail" summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ROOT_DIR="$(get_repo_root "${BASH_SOURCE[0]}")"
DEPLOY_DIR_GLOB="$ROOT_DIR/ke-net-screen-build/deploy-*"
USAGE="Usage: $0 [deploy_dir] [--rootfs DIR] [--build-log FILE] [--artifacts-only|--rootfs-only]"

DEPLOY_ARG=""; ROOTFS=""; BUILD_LOG=""; DO_ARTIFACTS=1; DO_ROOTFS=1
while (( $# )); do
  case "$1" in
    --rootfs)         ROOTFS=${2:?--rootfs needs a directory}; shift ;;
    --build-log)      BUILD_LOG=${2:?--build-log needs a file}; shift ;;
    --artifacts-only) DO_ROOTFS=0 ;;
    --rootfs-only)    DO_ARTIFACTS=0 ;;
    -h|--help)        sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               echo "$USAGE"; exit 2 ;;
    *)                [[ -z "$DEPLOY_ARG" ]] || { echo "$USAGE"; exit 2; }; DEPLOY_ARG=$1 ;;
  esac
  shift
done

# ---------------------------------------------------------------- phase 2 worker
# Runs only inside `podman unshare` (KE_VALIDATE_ROOTFS_WORKER=1, set by the driver below).
# It is its own process, so its counting pass/warn/fail helpers may shadow common.sh's
# fail(). The checks test exit codes themselves, so -e is switched off for them: under -e
# the first `grep -c` with no match would abort the run.
rootfs_checks() {   # rootfs_checks <rootfs-dir> [build-log]
set +e
ROOT=$1
BUILD_LOG=${2:-}
REPO=$ROOT_DIR
[[ -d "$ROOT/etc" && -d "$ROOT/usr" ]] || { echo "not a rootfs: $ROOT" >&2; return 2; }

P=0; W=0; F=0
pass() { P=$((P+1)); printf 'PASS  %s\n' "$*"; }
warn() { W=$((W+1)); printf 'WARN  %s\n' "$*"; }
fail() { F=$((F+1)); printf 'FAIL  %s\n' "$*"; }
sec()  { printf '\n--- %s\n' "$*"; }
note() { printf 'NOTE  %s\n' "$*"; }                        # informational, not counted
# ok <description> <command...>  — PASS when the command succeeds, else FAIL
ok()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
has()  { grep -qE -- "$2" "$ROOT/$1" 2>/dev/null; }          # has <file> <regex>
same() { [[ -f "$ROOT/$2" ]] && cmp -s "$1" "$ROOT/$2"; }     # same <source> <rootfs-path>
inroot() { chroot "$ROOT" "$@"; }                             # host and image are both arm64

# ------------------------------------------------------------------ A. build integrity
sec "A. Build integrity"
ok "Pi-hole installer present (basic-install.sh)" test -s "$ROOT/usr/local/src/pihole-installer/basic-install.sh"
ok "first-boot runner present and executable" test -x "$ROOT/usr/local/sbin/run-pihole-firstboot.sh"
ok "first-boot service enabled" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/run-pihole-firstboot.service"
for b in unbound unbound-anchor unbound-checkconf unbound-control unbound-host; do
    ok "source-built $b installed" test -x "$ROOT/usr/sbin/$b"
done
UV=$(inroot /usr/sbin/unbound -V 2>/dev/null | head -1)
if [[ "$UV" =~ ^Version\ 1\.26\. ]]; then pass "unbound runs in the image: $UV"; else fail "unbound -V unexpected: '${UV:-no output}'"; fi
UVFULL=$(inroot /usr/sbin/unbound -V 2>/dev/null)
for feat in "dns64" "validator" "iterator"; do
    if grep -q "$feat" <<<"$UVFULL"; then pass "unbound module linked: $feat"; else fail "unbound module missing: $feat"; fi
done
if CC=$(inroot /usr/sbin/unbound-checkconf /etc/unbound/unbound.conf 2>&1); then
    pass "unbound-checkconf accepts the shipped configuration (inside the image)"
else
    # the trust anchor is created at first boot; that alone is not a config fault
    if grep -qiE "root\.key|auto-trust-anchor|anchor" <<<"$CC"; then
        warn "unbound-checkconf: only the first-boot trust anchor is missing ($(tail -1 <<<"$CC" | cut -c1-90))"
    else
        fail "unbound-checkconf rejects the shipped configuration: $(tail -1 <<<"$CC" | cut -c1-120)"
    fi
fi
if command -v readelf >/dev/null; then
    for b in usr/sbin/unbound usr/sbin/unbound-control; do
        h=$(readelf -hldW "$ROOT/$b" 2>/dev/null); s=$(readelf -sW --dyn-syms "$ROOT/$b" 2>/dev/null)
        grep -q "Type:.*DYN" <<<"$h"      && pass "$b: PIE"            || fail "$b: not PIE"
        grep -q "GNU_RELRO" <<<"$h"       && pass "$b: RELRO"          || fail "$b: no RELRO"
        grep -qE "BIND_NOW|FLAGS.*NOW" <<<"$h" && pass "$b: BIND_NOW (full RELRO)" || warn "$b: lazy binding (partial RELRO)"
        grep -q "GNU_STACK.*RW " <<<"$h"  && pass "$b: non-executable stack" || fail "$b: executable stack"
        grep -q "__stack_chk_fail" <<<"$s" && pass "$b: stack protector" || warn "$b: no stack protector symbol"
        grep -qE "__[a-z]+_chk" <<<"$s"    && pass "$b: FORTIFY_SOURCE"  || warn "$b: no fortified calls seen"
    done
else
    warn "readelf not on this host — binary hardening flags not checked"
fi
if AUD=$(inroot dpkg --audit 2>&1) && [[ -z "$AUD" ]]; then pass "dpkg --audit: no half-installed or unconfigured packages"; else fail "dpkg --audit reports problems: $(head -2 <<<"$AUD" | tr '\n' ' ' | cut -c1-120)"; fi
ND=$(inroot dpkg-divert --list 2>/dev/null | grep -c unbound)
(( ND > 0 )) && pass "dpkg diversions protect the source-built unbound ($ND)" || fail "no unbound dpkg diversions"
if [[ -n "$BUILD_LOG" && -f "$BUILD_LOG" ]]; then
    # "cp: " only at line start or after a space: the log echoes hook source, and a bare
    # "cp: " also matches inside words like "incoming-num-tcp: " (false FAIL, 2026-11-22).
    n=$(grep -a -cE "cannot access|No such file|(^|[[:space:]])cp: " "$BUILD_LOG")
    (( n == 0 )) && pass "build log: no 'cannot access / No such file / cp:' lines" || fail "build log: $n copy/missing-file lines (inspect; never quote IGconf lines)"
    n=$(grep -a -ciE "\b(E:|dpkg: error|Traceback|Segmentation fault)" "$BUILD_LOG")
    (( n == 0 )) && pass "build log: no apt/dpkg errors or tracebacks" || fail "build log: $n apt/dpkg error lines"
fi

# ------------------------------------------------------------------ B. SSH
sec "B. SSH"
SC=etc/ssh/sshd_config.d/local_network_only.conf
ok "ssh policy file installed" test -s "$ROOT/$SC"
has $SC '^PermitRootLogin no'                  && pass "PermitRootLogin no" || fail "PermitRootLogin is not 'no'"
has $SC '^AddressFamily inet'                  && pass "ssh AddressFamily inet" || fail "ssh AddressFamily not pinned"
if has $SC 'IGconf_'; then fail "ssh policy still contains an unrendered IGconf_ placeholder"; else pass "ssh policy placeholders rendered"; fi
if has $SC '^ListenAddress ([0-9]{1,3}\.){3}[0-9]{1,3}$'; then pass "ssh ListenAddress is a single IPv4 address"; else fail "ssh ListenAddress missing or not an IPv4 address"; fi
has $SC '^KbdInteractiveAuthentication no'      && pass "keyboard-interactive auth off" || fail "keyboard-interactive auth not disabled"
if grep -hE '^(Ciphers|MACs|KexAlgorithms)' "$ROOT/$SC" | grep -qiE 'cbc|arcfour|3des|hmac-md5|hmac-sha1[^-]|hmac-sha1$|umac-64|diffie-hellman-group1-|group14-sha1|group-exchange-sha1'; then
    fail "weak ssh cipher/MAC/KEX present"; else pass "ssh ciphers/MACs/KEX: no CBC, SHA-1, MD5 or legacy DH"; fi
has $SC '^MACs .*-etm@' && pass "ssh MACs are encrypt-then-MAC" || warn "ssh MACs not restricted to ETM"
has $SC '^KexAlgorithms .*mlkem768x25519-sha256' && pass "ssh offers the ML-KEM post-quantum hybrid key exchange" || warn "ssh KexAlgorithms lacks mlkem768x25519-sha256 (no PQ hybrid for OpenSSH 10 clients)"
# sshd -t on the image itself: a mistyped algorithm or option stops sshd at boot and
# leaves only the console. Host keys are generated per device at first boot, so a
# throwaway key is used (the "Unable to load host key" line for the configured path is
# expected). /dev and /run are tmpfs mounts in a throwaway mount namespace: the rootfs
# is not written.
if [[ -x "$ROOT/usr/sbin/sshd" ]] && command -v unshare >/dev/null; then
    SSHDT=$(unshare -m sh -c '
        for d in run dev; do mount -t tmpfs -o mode=0755 tmpfs "$1/$d" || exit 90; done
        for n in null zero urandom random; do { : > "$1/dev/$n" && mount --bind "/dev/$n" "$1/dev/$n"; } || exit 90; done
        mkdir -p "$1/run/sshd"
        chroot "$1" /usr/bin/ssh-keygen -q -t ed25519 -N "" -f /run/ke-sshd-t-key || exit 90
        chroot "$1" /usr/sbin/sshd -t -h /run/ke-sshd-t-key' sh "$ROOT" 2>&1)
    RC=$?
    SSHDT=$(grep -v '^Unable to load host key: /etc/ssh/ssh_host_' <<<"$SSHDT")
    if (( RC == 0 )) && [[ -z "$SSHDT" ]]; then pass "sshd -t accepts the image's sshd configuration"
    elif (( RC == 0 )); then warn "sshd -t passed with messages: $(head -2 <<<"$SSHDT" | tr '\n' ' ')"
    elif (( RC == 90 )); then warn "sshd -t not run (private /dev, /run or throwaway key failed): $(head -1 <<<"$SSHDT")"
    else fail "sshd -t rejects the image's sshd configuration: $(head -2 <<<"$SSHDT" | tr '\n' ' ')"; fi
else
    warn "sshd -t not run (no sshd in the image, or no unshare on the build host)"
fi
if has etc/ssh/sshd_config '^Include /etc/ssh/sshd_config\.d/\*\.conf'; then pass "sshd_config includes the drop-in directory"; else fail "sshd_config does not include sshd_config.d"; fi
OTHER=$(ls "$ROOT/etc/ssh/sshd_config.d/" 2>/dev/null | grep -v '^local_network_only.conf$' | tr '\n' ' ')
[[ -z "$OTHER" ]] && pass "no other sshd drop-ins that could override the policy" || warn "other sshd drop-ins present (first match wins): $OTHER"
HK=$(ls "$ROOT"/etc/ssh/ssh_host_*_key 2>/dev/null | wc -l)
(( HK == 0 )) && pass "no ssh host keys baked into the image (generated per device)" || fail "$HK ssh host private key(s) baked into the image — every flashed card would share them"
if [[ -s "$ROOT/root/.ssh/authorized_keys" ]]; then fail "root has authorized_keys"; else pass "no authorized_keys for root"; fi
AK=$(find "$ROOT/home" -name authorized_keys -size +0 2>/dev/null | wc -l)
(( AK == 0 )) && pass "no authorized_keys baked in for any user" || warn "$AK authorized_keys file(s) baked into the image"

# ------------------------------------------------------------------ C. accounts and privilege
sec "C. Accounts and privilege"
U0=$(awk -F: '$3==0{print $1}' "$ROOT/etc/passwd" | tr '\n' ' ')
[[ "$U0" == "root " ]] && pass "only root has uid 0" || fail "uid 0 accounts: $U0"
RH=$(awk -F: '$1=="root"{print $2}' "$ROOT/etc/shadow")
[[ "$RH" == "*" || "$RH" == "!"* ]] && pass "root password locked" || fail "root has a usable password hash"
EMPTY=$(awk -F: '$2==""{print $1}' "$ROOT/etc/shadow" | tr '\n' ' ')
[[ -z "$EMPTY" ]] && pass "no account with an empty password" || fail "empty password: $EMPTY"
WITHPW=$(awk -F: '$2 ~ /^\$/{print $1}' "$ROOT/etc/shadow" | tr '\n' ' ')
NPW=$(wc -w <<<"$WITHPW")
(( NPW <= 1 )) && pass "accounts with a password hash: ${WITHPW:-none}" || warn "more than one account has a password hash: $WITHPW"
WEAKH=$(awk -F: '$2 ~ /^\$(1|5)\$/ || ($2 !~ /^[\$!*]/ && $2 != ""){print $1}' "$ROOT/etc/shadow" | tr '\n' ' ')
[[ -z "$WEAKH" ]] && pass "password hashes use yescrypt/SHA-512 (no MD5/SHA-256/DES)" || fail "weak password hash scheme: $WEAKH"
LOGINSH=$(awk -F: '$3>0 && $3<1000 && $7 !~ /(nologin|false|sync)$/{print $1}' "$ROOT/etc/passwd" | tr '\n' ' ')
[[ -z "$LOGINSH" ]] && pass "no system account has a login shell" || warn "system accounts with a login shell: $LOGINSH"
SM="$(stat -c '%a' "$ROOT/etc/shadow") $(inroot stat -c '%U:%G' /etc/shadow)"
[[ "$SM" == "640 root:shadow" || "$SM" == "600 root:root" ]] && pass "/etc/shadow is $SM" || fail "/etc/shadow is $SM"
BADSUDO=0
for f in "$ROOT"/etc/sudoers "$ROOT"/etc/sudoers.d/*; do
    [[ -f "$f" ]] || continue
    m=$(stat -c '%a %u' "$f")
    [[ "$m" == "440 0" ]] && continue
    if [[ "$m" =~ ^[0-7][0145][0145]\ 0$ ]]; then BADSUDO=$((BADSUDO<1?1:BADSUDO)); else BADSUDO=2; fi
    echo "      ${f#$ROOT} is mode ${m% *} uid ${m#* }"
done
case $BADSUDO in
    0) pass "sudoers files are 0440 root" ;;
    1) warn "sudoers file(s) root-owned and not writable by others, but not the 0440 that visudo -c demands (listed above)" ;;
    *) fail "sudoers file writable by non-root or not root-owned" ;;
esac
NOPW=$(grep -rhE '^[^#].*NOPASSWD' "$ROOT/etc/sudoers" "$ROOT/etc/sudoers.d" 2>/dev/null | wc -l)
(( NOPW == 0 )) && pass "no NOPASSWD sudo rule in the image (cache-dump grant stays an operator opt-in)" || fail "$NOPW NOPASSWD sudo rule(s) baked into the image"
VS=$(inroot visudo -c 2>&1 | grep -v "parsed OK")
if [[ -z "$VS" ]]; then pass "visudo -c: sudoers syntax and modes valid"
elif grep -qv "bad permissions" <<<"$VS"; then fail "visudo -c: $(grep -v 'bad permissions' <<<"$VS" | head -1 | cut -c1-120)"
else pass "visudo -c: every sudoers file parses (mode complaint reported above)"; fi

# ------------------------------------------------------------------ D. filesystem permissions
sec "D. Filesystem permissions"
WW=$(find "$ROOT" -xdev \( -path "$ROOT/proc" -o -path "$ROOT/sys" -o -path "$ROOT/dev" \) -prune -o -type f -perm -0002 -print 2>/dev/null | wc -l)
(( WW == 0 )) && pass "no world-writable files" || fail "$WW world-writable file(s)"
WWD=$(find "$ROOT" -xdev \( -path "$ROOT/proc" -o -path "$ROOT/sys" -o -path "$ROOT/dev" \) -prune -o -type d -perm -0002 ! -perm -1000 -print 2>/dev/null | wc -l)
(( WWD == 0 )) && pass "no world-writable directory without the sticky bit" || fail "$WWD world-writable non-sticky directories"
SUID=$(find "$ROOT" -xdev -type f -perm -4000 -printf '/%P\n' 2>/dev/null | sort)
EXPECT_SUID='^/usr/(bin/(chfn|chsh|gpasswd|mount|newgrp|passwd|su|sudo|umount|fusermount3?|pkexec)|lib/(dbus-1\.0/dbus-daemon-launch-helper|openssh/ssh-keysign|polkit-1/polkit-agent-helper-1)|sbin/(mount\.nfs|unix_chkpwd))$'
UNX=$(grep -vE "$EXPECT_SUID" <<<"$SUID" | grep . | tr '\n' ' ')
[[ -z "$UNX" ]] && pass "setuid binaries: $(grep -c . <<<"$SUID"), all on the expected Debian list" || warn "setuid binaries outside the expected list: $UNX"
UNOWN=$(inroot find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o \( -nouser -o -nogroup \) -print 2>/dev/null | wc -l)
(( UNOWN == 0 )) && pass "no files with an unknown owner or group" || warn "$UNOWN file(s) owned by a uid/gid not in the image's passwd/group"
NRX=0
for f in "$ROOT"/usr/local/bin/* "$ROOT"/usr/local/sbin/*; do
    [[ -f "$f" ]] || continue
    [[ "$(stat -c '%u' "$f")" == 0 && ! $(stat -c '%a' "$f") =~ [2367]$ && ! $(stat -c '%a' "$f") =~ ^.?[2367].$ ]] || { NRX=$((NRX+1)); echo "      ${f#$ROOT} $(stat -c '%a %U' "$f")"; }
done
(( NRX == 0 )) && pass "operator scripts in /usr/local/{bin,sbin} are root-owned, not group/world-writable" || fail "$NRX operator script(s) writable by non-root"
UNITW=$(find "$ROOT/etc/systemd/system" -type f \( -perm -0020 -o -perm -0002 \) 2>/dev/null | wc -l)
(( UNITW == 0 )) && pass "systemd unit files are not group/world-writable" || fail "$UNITW writable unit file(s)"

# ------------------------------------------------------------------ E. kernel / sysctl / modules
sec "E. Kernel, sysctl, modules"
for f in etc/sysctl.d/00-swappiness.conf etc/sysctl.d/20-iodiskperf.conf etc/sysctl.d/99-unbound-tuning.conf etc/modprobe.d/ke-appliance-blacklist.conf; do
    same "$REPO/$f" "$f" && pass "$f matches the repo" || fail "$f missing or differs from the repo"
done
# In systemd-sysctl's order: every *.conf of /usr/lib, /usr/local/lib and /etc sysctl.d,
# sorted by file NAME, a name in /etc masking the same name below it; the last
# assignment of a key wins (so 60-* overrides systemd's 50-default.conf).
declare -A SYSF=()
for f in "$ROOT"/usr/lib/sysctl.d/*.conf "$ROOT"/usr/local/lib/sysctl.d/*.conf "$ROOT"/etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] && SYSF[${f##*/}]=$f
done
ALLSYS=$(for n in $(printf '%s\n' "${!SYSF[@]}" | LC_ALL=C sort); do sed 's/#.*//' "${SYSF[$n]}"; done)
want_sysctl() { # key value; the key may be a sysctl.d pattern (net.ipv4.conf.*.rp_filter), matched literally
    local re last; re=$(sed 's/[][\.*^$]/\\&/g' <<<"$1")
    last=$(grep -E "^\s*$re\s*=" <<<"$ALLSYS" | tail -1 | sed -E 's/.*=\s*//; s/\s+$//')
    [[ "$last" == "$2" ]] && pass "sysctl $1 = $2" || fail "sysctl $1 = '${last:-unset}' (want $2)"
}
# 60-net-observe.conf is the repo's OPTIONAL anti-spoof/redirect file: no layer installs it.
if [[ -f "$ROOT/etc/sysctl.d/60-net-observe.conf" ]]; then
    same "$REPO/etc/sysctl.d/60-net-observe.conf" etc/sysctl.d/60-net-observe.conf && pass "60-net-observe.conf matches the repo" || fail "60-net-observe.conf differs from the repo"
    for k in net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects net.ipv4.conf.all.send_redirects \
             net.ipv4.conf.all.accept_source_route net.ipv6.conf.all.accept_redirects net.ipv6.conf.all.accept_source_route \
             net.ipv4.conf.all.secure_redirects; do want_sysctl "$k" 0; done
    want_sysctl net.ipv4.conf.all.rp_filter 1
    want_sysctl 'net.ipv4.conf.*.rp_filter' 1          # else eth0 keeps systemd's loose 2
    want_sysctl 'net.ipv6.conf.*.accept_redirects' 0   # else eth0 keeps the kernel's 1
    want_sysctl net.ipv4.conf.all.log_martians 1
    same "$REPO/etc/sysctl.d/61-kernel-harden.conf" etc/sysctl.d/61-kernel-harden.conf && pass "61-kernel-harden.conf matches the repo" || fail "61-kernel-harden.conf missing or differs (SYSCTL_HARDENING installs both files)"
else
    warn "posture: SYSCTL_HARDENING is off — optional etc/sysctl.d/60-net-observe.conf is NOT in the image — ICMP redirects accepted and sent, martians not logged, rp_filter left at the distro default"
fi
# One-file kernel toggles (SYSCTL_NO_*), independent of SYSCTL_HARDENING; absent = off.
for spec in "62-ke-no-tiocsti.conf:dev.tty.legacy_tiocsti:0:SYSCTL_NO_TIOCSTI" \
            "63-ke-no-ldisc-autoload.conf:dev.tty.ldisc_autoload:0:SYSCTL_NO_LDISC_AUTOLOAD" \
            "64-ke-no-io-uring.conf:kernel.io_uring_disabled:2:SYSCTL_NO_IO_URING"; do
    IFS=: read -r tf tk tv tt <<<"$spec"
    if [[ -f "$ROOT/etc/sysctl.d/$tf" ]]; then
        same "$REPO/etc/sysctl.d/$tf" "etc/sysctl.d/$tf" && pass "$tf matches the repo ($tt=y)" || fail "$tf differs from the repo"
        want_sysctl "$tk" "$tv"
    else
        note "$tt off: $tf not in the image ($tk stays at the kernel default)"
    fi
done
if grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1|^\s*net\.ipv6\.conf\.all\.forwarding\s*=\s*1' <<<"$ALLSYS"; then fail "IP forwarding enabled by a sysctl file"; else pass "no sysctl file enables IP forwarding"; fi
# hardening sysctls the repo does not set today: report as advisory, not failure
# (unprivileged_bpf_disabled=2 and tcp_syncookies=1 are this kernel's built-in defaults,
#  read on the live appliance 2026-11-15; the Yama LSM is not built into the Pi kernel.)
for kv in "kernel.kptr_restrict=1" "kernel.dmesg_restrict=1" "fs.protected_hardlinks=1" "fs.protected_symlinks=1"; do
    k=${kv%%=*}; v=${kv##*=}; last=$(grep -E "^\s*$k\s*=" <<<"$ALLSYS" | tail -1 | sed -E 's/.*=\s*//; s/\s+$//')
    if [[ -z "$last" ]]; then warn "advisory: $k not set by any sysctl file (kernel default applies; hardened value $v)"
    elif (( last >= v )); then pass "sysctl $k = $last"; else warn "advisory: $k = $last (hardened value $v)"; fi
done

# ------------------------------------------------------------------ F. systemd units
sec "F. systemd units"
for t in dns-health-check ke-maintenance net-snapshot power-report pihole-gravity pihole-logflush; do
    ok "$t.timer enabled" test -L "$ROOT/etc/systemd/system/timers.target.wants/$t.timer"
    ok "$t.service present" test -s "$ROOT/etc/systemd/system/$t.service"
done
ok "stunnel-cert-watch.path enabled" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/stunnel-cert-watch.path"
ok "stunnel cert guard executable" test -x "$ROOT/usr/local/sbin/stunnel-cert-guard.sh"
DANG=$(inroot find /etc/systemd/system -xtype l ! -lname /dev/null 2>/dev/null | tr '\n' ' ')
[[ -z "$DANG" ]] && pass "no dangling unit symlinks" || fail "dangling unit symlinks: $DANG"
# Lesson of 2026-11-15: systemd expands %X specifiers and \${VAR} inside Exec lines.
BADX=0
while IFS= read -r line; do
    f=${line%%:*}; body=${line#*:}
    stripped=${body//%%/}
    if grep -qE '%[A-Za-z]' <<<"$stripped" && grep -qE '(/bin/(ba)?sh -c|date \+)' <<<"$body"; then
        BADX=$((BADX+1)); echo "      ${f#$ROOT}: single % in a shell Exec line"
    fi
    if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*[^A-Za-z0-9_}]' <<<"$body"; then
        BADX=$((BADX+1)); echo "      ${f#$ROOT}: \${...} with a shell operator in an Exec line (systemd expands it to empty)"
    fi
done < <(grep -rHE '^Exec(Start|StartPre|StartPost|Stop|Reload)=' "$ROOT/etc/systemd/system" 2>/dev/null)
(( BADX == 0 )) && pass "no Exec line with an unescaped % specifier or shell-style \${...}" || fail "$BADX Exec line(s) that systemd would rewrite before the shell runs"
EXMISS=0
while IFS= read -r line; do
    f=${line%%:*}; exe=$(sed -E 's/^Exec[A-Za-z]+=[-@:+!]*//' <<<"${line#*:}" | awk '{print $1}')
    [[ "$exe" == /* ]] || continue
    [[ -e "$ROOT$exe" || -L "$ROOT$exe" ]] || { EXMISS=$((EXMISS+1)); echo "      ${f#$ROOT}: $exe not in the image"; }
done < <(grep -rHE '^Exec(Start|StartPre|StartPost)=' "$ROOT/etc/systemd/system" 2>/dev/null)
(( EXMISS == 0 )) && pass "every Exec binary named by a ke unit exists in the image" || warn "$EXMISS Exec target(s) absent at build time (expected only for binaries the first-boot installer provides)"
if command -v systemd-analyze >/dev/null; then
    VOUT=$(systemd-analyze verify --root="$ROOT" --man=no "$ROOT"/etc/systemd/system/{dns-health-check,ke-maintenance,net-snapshot,power-report}.{service,timer} 2>&1 | grep -vE "^$" | grep -E "/etc/systemd/system/(dns-health-check|ke-maintenance|net-snapshot|power-report)" )
    [[ -z "$VOUT" ]] && pass "systemd-analyze verify: ke monitoring/maintenance units parse cleanly" || warn "systemd-analyze verify: $(wc -l <<<"$VOUT") note(s): $(head -2 <<<"$VOUT" | cut -c1-140 | tr '\n' '|')"
fi
MID=$(stat -c%s "$ROOT/etc/machine-id" 2>/dev/null || echo 0)
if (( MID <= 1 )) || grep -qx uninitialized "$ROOT/etc/machine-id" 2>/dev/null; then pass "machine-id not baked in (unique per device)"; else fail "machine-id is baked into the image — every card would share it"; fi

# ------------------------------------------------------------------ G. services configuration
sec "G. Service configuration"
same "$REPO/etc/unbound/unbound.conf.d/pi-hole.conf" etc/unbound/unbound.conf.d/pi-hole.conf && pass "unbound pi-hole.conf matches the repo" || fail "unbound pi-hole.conf missing or differs"
same "$REPO/etc/unbound/unbound.conf.d/ke-observability.conf" etc/unbound/unbound.conf.d/ke-observability.conf && pass "unbound ke-observability.conf matches the repo" || fail "ke-observability.conf missing or differs"
UC=etc/unbound/unbound.conf.d/pi-hole.conf
# UNBOUND_INCOMING_NUM_TCP: a drop-in only when the value is not Unbound's default 10.
UT=etc/unbound/unbound.conf.d/ke-incoming-tcp.conf
if [[ -f "$ROOT/$UT" ]]; then
    NTCP=$(sed -n 's/^[[:space:]]*incoming-num-tcp:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$ROOT/$UT")
    if [[ -n "$NTCP" ]] && (( NTCP >= 1 && NTCP <= 40 )); then pass "unbound incoming-num-tcp $NTCP (UNBOUND_INCOMING_NUM_TCP; within the 1,024-fd budget)"
    else fail "$UT: incoming-num-tcp '${NTCP:-?}' missing or outside 1-40"; fi
else
    note "UNBOUND_INCOMING_NUM_TCP default: Unbound's incoming-num-tcp 10 (no drop-in)"
fi
has $UC '^\s*interface: 127\.0\.0\.1'       && pass "unbound listens on loopback only" || fail "unbound interface is not loopback"
if grep -E '^\s*interface:' "$ROOT/$UC" | grep -qvE '127\.0\.0\.1|::1'; then fail "unbound has a non-loopback interface line"; else pass "no non-loopback unbound interface"; fi
has $UC '^\s*harden-glue: yes'              && pass "unbound harden-glue" || fail "harden-glue off"
has $UC '^\s*harden-dnssec-stripped: yes'   && pass "unbound harden-dnssec-stripped" || fail "harden-dnssec-stripped off"
has $UC 'validator'                         && pass "DNSSEC validator in module-config" || fail "validator missing from module-config"
has $UC '^\s*private-address: 192\.168\.0\.0/16' && pass "DNS-rebinding protection (private-address)" || fail "private-address rebinding protection missing"
if grep -rqE '^\s*(forward-addr|forward-host):' "$ROOT/etc/unbound" 2>/dev/null; then warn "unbound has a forwarder configured (design is full recursion)"; else pass "unbound is a full recursor (no forwarders)"; fi
if grep -rqE '^\s*control-interface:\s*(0\.0\.0\.0|::0|::$|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' "$ROOT/etc/unbound" 2>/dev/null && ! grep -rqE '^\s*control-interface:\s*127\.' "$ROOT/etc/unbound"; then fail "unbound remote-control bound beyond loopback"; else pass "unbound remote-control not exposed beyond loopback"; fi
SD=etc/stunnel/dot.conf
ok "stunnel DoT config present" test -s "$ROOT/$SD"
has $SD '^\s*setuid = stunnel4' && has $SD '^\s*setgid = stunnel4' && pass "stunnel drops privilege to stunnel4" || fail "stunnel privilege drop missing"
has $SD '^\s*sslVersionMin = TLSv1\.[23]' && pass "stunnel minimum TLS 1.2+" || fail "stunnel sslVersionMin not pinned"
has $SD '^\s*connect = 127\.0\.0\.1:53' && pass "stunnel forwards to the local resolver only" || fail "stunnel connect target unexpected"
# DOT_TLS_HARDENING=y: ML-KEM-first key exchange and AEAD-only TLS 1.2.
if has $SD '^\s*curves\s*=' || has $SD '^\s*ciphers\s*='; then
    has $SD '^curves = X25519MLKEM768:' && pass "DoT key exchange offers ML-KEM-768 + X25519 first (DOT_TLS_HARDENING=y)" || fail "DoT curves line present but X25519MLKEM768 is not first"
    has $SD '^ciphers = ECDHE\+AESGCM:ECDHE\+CHACHA20$' && pass "DoT TLS 1.2 limited to AEAD suites (no CBC, no SHA-1 MAC)" || fail "DoT ciphers line is not the AEAD-only list"
elif [[ -s "$ROOT/$SD" ]]; then
    note "DOT_TLS_HARDENING off: stunnel default groups (no ML-KEM) and TLS 1.2 CBC suites accepted"
fi
if [[ -e "$ROOT/etc/pihole/tls.pem" ]]; then fail "tls.pem (private key) baked into the image"; else pass "no TLS private key baked in (issued at first boot)"; fi
KEYS=$(grep -rlE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$ROOT/etc" "$ROOT/usr/local" "$ROOT/root" "$ROOT/home" 2>/dev/null | grep -vE '/ssl/private/ssl-cert-snakeoil\.key$' | sed "s|$ROOT||" | tr '\n' ' ')
[[ -z "$KEYS" ]] && pass "no private keys anywhere under /etc, /usr/local, /root, /home" || fail "private key material in the image: $KEYS"
same "$REPO/etc/systemd/journald.conf.d/ke-journald.conf" etc/systemd/journald.conf.d/ke-journald.conf && pass "journald budget drop-in matches the repo" || fail "journald drop-in missing or differs"
same "$REPO/etc/systemd/timesyncd.conf.d/ke-timesync.conf" etc/systemd/timesyncd.conf.d/ke-timesync.conf && pass "timesyncd drop-in matches the repo" || fail "timesyncd drop-in missing or differs"
same "$REPO/etc/avahi/avahi-daemon.conf" etc/avahi/avahi-daemon.conf && pass "avahi-daemon.conf matches the repo" || warn "avahi-daemon.conf differs from the repo (rendered at build?)"
same "$REPO/etc/apt/apt.conf.d/52ke-unattended-upgrades" etc/apt/apt.conf.d/52ke-unattended-upgrades && pass "unattended-upgrades policy matches the repo" || fail "unattended-upgrades policy missing or differs"
same "$REPO/etc/apt/apt.conf.d/20auto-upgrades" etc/apt/apt.conf.d/20auto-upgrades && pass "auto-upgrades switch matches the repo" || fail "20auto-upgrades missing or differs"
has etc/apt/apt.conf.d/52ke-unattended-upgrades 'Automatic-Reboot "false"' && pass "unattended-upgrades never reboots on its own" || fail "Automatic-Reboot not false"
inroot dpkg -s unattended-upgrades >/dev/null 2>&1 && pass "unattended-upgrades package installed" || fail "unattended-upgrades package not installed"
BADPK=""
for p in telnetd inetutils-telnetd rsh-server rsh-redone-server vsftpd proftpd-basic tftpd-hpa nfs-kernel-server samba snmpd xinetd rpcbind apache2 nginx lighttpd; do
    inroot dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed' && BADPK+="$p "
done
[[ -z "$BADPK" ]] && pass "no legacy/unneeded network daemons installed (telnet, ftp, rsh, nfs, samba, snmp, rpcbind, web servers)" || fail "unwanted network daemon package(s): $BADPK"
if grep -rhE -v '^\s*(//|#)' "$ROOT/etc/apt/sources.list" "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/apt/apt.conf.d" 2>/dev/null | grep -qE 'http://(localhost|127\.|192\.168\.|10\.)|file:/home|Acquire::.*Proxy|Dir::Cache'; then fail "apt config points at a build-host cache/proxy"; else pass "apt config carries no build-host cache or proxy"; fi
if grep -rhE '^\s*(deb|URIs:)' "$ROOT/etc/apt/sources.list" "$ROOT/etc/apt/sources.list.d" 2>/dev/null | grep -q 'http://'; then
    if grep -rqE 'Signed-By|signed-by' "$ROOT/etc/apt/sources.list" "$ROOT/etc/apt/sources.list.d" 2>/dev/null; then pass "apt sources are signature-pinned (Signed-By) — plain http transport is integrity-protected"; else warn "apt sources use http without Signed-By pinning"; fi
else pass "apt sources use https only"; fi

# ------------------------------------------------------------------ H. private configuration and leak checks
sec "H. Private configuration and leaks"
if [[ -f "$REPO/private/pihole.toml" ]]; then
    PT=""
    c=etc/pihole/pihole.toml
    # Report key NAMES only. Other differing lines (list entries such as dhcp.hosts
    # "MAC,IP,name", comments) are counted, never printed: they hold household data.
    DIFFL=$(diff "$REPO/private/pihole.toml" "$ROOT/$c" 2>/dev/null | grep '^[<>]' | sed -E 's/^[<>]\s*//')
    DK=$(grep -E '^[A-Za-z0-9_.-]+\s*=' <<<"$DIFFL" | sed -E 's/\s*=.*//' | sort -u | tr '\n' ' ')
    NL=$(grep -cvE '^[A-Za-z0-9_.-]+\s*=|^\s*$' <<<"$DIFFL")
    if [[ ! -f "$ROOT/$c" ]]; then fail "no pihole.toml in the image"
    elif [[ -z "$DIFFL" ]]; then pass "image carries the PRIVATE pihole.toml, byte-identical"
    elif [[ "$DK" == "IPv4 " && "$NL" == 0 ]]; then pass "image carries the PRIVATE pihole.toml (only the build-rendered IPv4 line differs)"
    else fail "image pihole.toml differs from the private source: keys [${DK% }] and $NL other line(s) (list entries/comments, not printed)"; fi
    cmp -s "$ROOT/etc/pihole/pihole.toml" "$ROOT/usr/local/src/pihole/pihole.toml" && pass "first-boot seed copy of pihole.toml matches /etc/pihole" || fail "the two pihole.toml copies in the image differ"
    NRES=$(grep -cE '^\s*"[0-9A-Fa-f:]{17},' "$REPO/private/pihole.toml")
    (( NRES > 0 )) && pass "private pihole.toml holds $NRES static DHCP reservation line(s)" || warn "no static DHCP reservations found in the private toml (pattern may not match its format)"
fi
if [[ -f "$REPO/private/adlists_export.csv" ]]; then
    AL=$(find "$ROOT/usr/local" "$ROOT/home" -name adlists_export.csv 2>/dev/null | head -1)
    [[ -n "$AL" ]] && cmp -s "$REPO/private/adlists_export.csv" "$AL" && pass "image carries the PRIVATE adlist export" || fail "image adlist export is not the private build source"
fi
if grep -rqsF 'Ch@ngeM3' "$ROOT/etc" "$ROOT/usr/local" "$ROOT/root" "$ROOT/home" 2>/dev/null; then fail "the PUBLIC example password is present in the image"; else pass "public example password not present in the image"; fi
ENVF="$REPO/.env.production"
if [[ -r "$ENVF" ]]; then
    PW=$(grep -m1 -E '^PIHOLE_PASSWORD=' "$ENVF" | sed -E "s/^PIHOLE_PASSWORD=//; s/^['\"]//; s/['\"]$//")
    if [[ ${#PW} -ge 6 ]]; then
        mapfile -t HITS < <(grep -rlsF -- "$PW" "$ROOT/etc" "$ROOT/usr/local" "$ROOT/root" "$ROOT/home" "$ROOT/var/lib" "$ROOT/opt" 2>/dev/null)
        LEAK=0
        for h in "${HITS[@]}"; do
            m=$(stat -c '%a' "$h")
            if [[ $m =~ [4567]$ ]]; then LEAK=$((LEAK+1)); echo "      world-readable file contains the admin password: ${h#$ROOT} ($m)"; else echo "      (restricted) password present in ${h#$ROOT} mode $m"; fi
        done
        (( LEAK == 0 )) && pass "admin password is not in any world-readable file (${#HITS[@]} restricted file(s) hold it for first boot)" || fail "$LEAK world-readable file(s) contain the admin password"
    else warn "could not read PIHOLE_PASSWORD from .env.production — plaintext-password scan skipped"; fi
    unset PW
fi
ENVIN=$(find "$ROOT" -xdev \( -name '.env' -o -name '.env.production' -o -name '.env.*' \) -type f 2>/dev/null | grep -vE '/(node_modules|python3?[^/]*)/' | sed "s|$ROOT||" | tr '\n' ' ')
[[ -z "$ENVIN" ]] && pass "no .env file copied into the image" || fail ".env file(s) in the image: $ENVIN"
BH=$(hostname)
if grep -rqsF -- "$BH" "$ROOT/etc" 2>/dev/null; then warn "build host name appears under /etc in the image: $(grep -rlsF -- "$BH" "$ROOT/etc" | sed "s|$ROOT||" | head -3 | tr '\n' ' ')"; else pass "build host name not present under /etc"; fi
if grep -rqsF -- "$REPO" "$ROOT/etc" "$ROOT/usr/local" 2>/dev/null; then warn "build host repo path appears in the image: $(grep -rlsF -- "$REPO" "$ROOT/etc" "$ROOT/usr/local" | sed "s|$ROOT||" | head -3 | tr '\n' ' ')"; else pass "no build-host path leaked into /etc or /usr/local"; fi
HIST=$(find "$ROOT/root" "$ROOT/home" -maxdepth 2 \( -name '.bash_history' -o -name '.viminfo' -o -name '.lesshst' -o -name '.python_history' \) -size +0 2>/dev/null | wc -l)
(( HIST == 0 )) && pass "no shell/editor history files in the image" || warn "$HIST history file(s) in the image"
has etc/hostname '^ke-' && pass "hostname set ($(cat "$ROOT/etc/hostname"))" || warn "hostname is '$(cat "$ROOT/etc/hostname" 2>/dev/null)'"

printf '\n===== rootfs hardening check: %d pass / %d warn / %d fail =====\n' "$P" "$W" "$F"
(( F == 0 ))
}

if [[ "${KE_VALIDATE_ROOTFS_WORKER:-}" == 1 ]]; then
  rootfs_checks "$ROOTFS" "$BUILD_LOG"
  exit $?
fi

# ---------------------------------------------------------------- phase 1: deploy artifacts
if (( DO_ARTIFACTS )); then
  DEPLOY_DIR="$(resolve_deploy_dir "$ROOT_DIR" "$DEPLOY_ARG")"

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
fi

# ---------------------------------------------------------------- phase 2: rootfs contents
if (( DO_ROOTFS )); then
  [[ -n "$ROOTFS" ]] || ROOTFS="$(ls -1dt "$ROOT_DIR"/ke-net-screen-build/chroot-*/filesystem 2>/dev/null | head -1 || true)"
  if [[ -z "$ROOTFS" || ! -d "$ROOTFS/etc" ]]; then
    if (( DO_ARTIFACTS )); then echo "[warn] no build rootfs on disk — rootfs content checks skipped"; exit 0; fi
    echo "[fail] no build rootfs found (pass --rootfs DIR)"; exit 1
  fi
  if ! command -v podman >/dev/null 2>&1; then
    if (( DO_ARTIFACTS )); then echo "[warn] podman not installed — rootfs content checks need the rootless build namespace; skipped"; exit 0; fi
    echo "[fail] podman not installed — rootfs content checks need the rootless build namespace"; exit 1
  fi
  if [[ -n "$BUILD_LOG" && ! -r "$BUILD_LOG" ]]; then
    echo "[fail] build log not readable: $BUILD_LOG"; exit 1
  fi
  echo ""
  echo "[check] rootfs contents: $ROOTFS${BUILD_LOG:+ (build log: $BUILD_LOG)}"
  set +e
  podman unshare env KE_VALIDATE_ROOTFS_WORKER=1 bash "$SCRIPT_DIR/validate-deploy-artifacts.sh" \
      --rootfs "$ROOTFS" ${BUILD_LOG:+--build-log "$BUILD_LOG"}
  rc=$?
  set -e
  if (( rc == 0 )); then
    echo "[ok] rootfs content checks passed (warnings above are advisory)"
  else
    echo "[fail] rootfs content checks failed (exit $rc; see the FAIL lines above)"
    exit 1
  fi
fi
