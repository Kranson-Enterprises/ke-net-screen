#!/bin/bash
# collect-appliance-logs.sh — pull the appliance's journal, monitor logs and unbound cache
# dump to this LAN host for review, and package the monitor logs together with a snapshot
# of host facts. Read-only on the appliance; nothing there is changed.
#
# Usage:
#   ./collect-appliance-logs.sh [options] [user@]host
#   ./collect-appliance-logs.sh 192.168.0.53                 # whole current boot, into private/inbox/
#   ./collect-appliance-logs.sh --since-last 192.168.0.53    # journal since the previous run (state file in --dest)
#   ./collect-appliance-logs.sh --dest ~/drops --no-dump admin@ke-localdns
#   ./collect-appliance-logs.sh --help
#
# Produces in DEST (default: <repo>/private/inbox when it exists, else the current directory):
#   journal-<hostname>-<YYMMDD-HHMM>.txt          journalctl -b (or --since the last run), short format
#   dns-cache-as-of-<YYMMDD-HH-MM>.txt            unbound-control dump_cache (root on the appliance; see Access)
#   appliance-logs-<hostname>-<YYMMDD-HHMM>.tar.gz
#       host-info.txt   hostname, uptime, kernel, model, SD card and sectors written, root fs,
#                       memory, failed units, our timers, service states and restart counts,
#                       FTL/unbound versions and diversions, journald and log sizes, ext4 error
#                       count, throttle/temperature, apt history tail, this boot's warnings
#       logs/           /var/log/dns-health.log*, net-snapshot.log*, power-report.log*
#                       (+ /var/log/pihole/FTL.log and webserver.log with --with-pihole-logs)
# then prints a short review: failed units, health-check ⚠/✗, under-voltage, SSH password
# logins, the last health verdict, the last power "trend" and net "snapshot" records.
#
# Options:
#   --dest DIR            where to write (see above)
#   --since-last          journal since the time saved by the previous run for this host
#   --no-dump             skip the unbound cache dump
#   --no-package          skip the tar.gz
#   --with-pihole-logs    add /var/log/pihole/FTL.log and webserver.log to the package
#   --keep-staging        leave the staging directory behind (debugging)
#
# Access: SSH as your normal user (key recommended; one connection is shared). The journal is
#   readable by members of adm / systemd-journal, everything else in the package needs no
#   privilege. The cache dump needs root: for unattended runs grant exactly that command
#   without a password on the appliance (mode 0440; check with visudo -cf first):
#     echo 'localadmin ALL=(root) NOPASSWD: /usr/sbin/unbound-control -c /etc/unbound/unbound.conf dump_cache' \
#       | sudo tee /etc/sudoers.d/ke-collect-dump
#   Without it the dump is skipped and everything else is still collected.
#
# The image also installs this script on the appliance (~/scripts/collect-appliance-logs.sh,
# layer ke-25-monitor) so it travels with the box; run it from another host against the appliance.
#
# Cron on this host (weekly, Monday 06:00, incremental journal):
#   0 6 * * 1  /path/to/ke-net-screen/home/scripts/network/collect-appliance-logs.sh --since-last 192.168.0.53 >> ~/collect-appliance.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEST=""; SINCE_LAST=0; DO_DUMP=1; DO_PACKAGE=1; PIHOLE_LOGS=0; KEEP=0; TARGET=""
WARNINGS=()

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "collect-appliance-logs.sh: $*" >&2; exit 1; }
note()  { printf '==> %s\n' "$*"; }
warn()  { printf '!!  %s\n' "$*" >&2; WARNINGS+=("$*"); }

while (( $# )); do
    case "$1" in
        --dest)             DEST=${2:?--dest needs a directory}; shift ;;
        --since-last)       SINCE_LAST=1 ;;
        --no-dump)          DO_DUMP=0 ;;
        --no-package)       DO_PACKAGE=0 ;;
        --with-pihole-logs) PIHOLE_LOGS=1 ;;
        --keep-staging)     KEEP=1 ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 die "unknown option '$1' (see --help)" ;;
        *)                  [[ -z "$TARGET" ]] || die "one target only (got '$TARGET' and '$1')"; TARGET=$1 ;;
    esac
    shift
done
[[ -n "$TARGET" ]] || die "target required, e.g. 192.168.0.53 or admin@ke-localdns (see --help)"
for t in ssh tar gzip; do command -v "$t" >/dev/null 2>&1 || die "$t not found on this host"; done
if [[ -z "$DEST" ]]; then
    if [[ -d "$REPO_ROOT/private/inbox" ]]; then DEST="$REPO_ROOT/private/inbox"; else DEST="$PWD"; fi
fi
mkdir -p "$DEST"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/collect-appliance.XXXXXX")
# One SSH connection shared by every step (at most one key/passphrase prompt).
SSH_OPTS=(-o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=120 -o "ControlPath=$STAGE/ssh-%C")
[[ -t 0 ]] || SSH_OPTS+=(-o BatchMode=yes)
cleanup() {
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
    (( KEEP )) && { echo "staging kept at $STAGE"; return; }
    rm -rf "$STAGE"
}
trap cleanup EXIT
rssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# ---------------------------------------------------------------- identify the appliance
note "Connecting to $TARGET"
REMOTE_ID=$(rssh 'printf "%s|%s\n" "$(hostname)" "$(date "+%Y-%m-%d %H:%M:%S")"') || die "ssh to $TARGET failed"
IFS='|' read -r RHOST RNOW <<<"$REMOTE_ID"
[[ -n "$RHOST" ]] || die "could not read the remote hostname"
STAMP=$(date '+%y%m%d-%H%M'); DUMP_STAMP=$(date '+%y%m%d-%H-%M')
STATE="$DEST/.collect-state-$RHOST"
note "$RHOST (remote clock $RNOW) -> $DEST"

# ---------------------------------------------------------------- journal
JOURNAL="$DEST/journal-$RHOST-$STAMP.txt"
JARGS=(-o short --no-pager -q)
if (( SINCE_LAST )) && [[ -s "$STATE" ]]; then
    SINCE=$(<"$STATE"); JARGS+=(--since "$SINCE"); note "Journal since $SINCE"
else
    JARGS+=(-b); note "Journal for the current boot$( ((SINCE_LAST)) && echo ' (no previous state for this host yet)')"
fi
JCMD="journalctl $(printf '%q ' "${JARGS[@]}")"
# adm / systemd-journal members read everything; anyone else sees only their own entries
# and a hint on stderr, in which case retry through sudo -n.
rssh "$JCMD" > "$JOURNAL" 2>"$STAGE/journal.err" || true
if [[ ! -s "$JOURNAL" ]] || grep -q 'not seeing messages' "$STAGE/journal.err"; then
    rssh "sudo -n $JCMD" > "$JOURNAL" 2>>"$STAGE/journal.err" || true
fi
if [[ -s "$JOURNAL" ]]; then
    note "journal: $(wc -l < "$JOURNAL") lines, $(stat -c%s "$JOURNAL") bytes"
    echo "$RNOW" > "$STATE"
else
    rm -f "$JOURNAL"; JOURNAL=""
    warn "journal empty: $(tr '\n' ' ' < "$STAGE/journal.err" | cut -c1-160)"
fi

# ---------------------------------------------------------------- package: host facts + monitor logs
PKG=""
if (( DO_PACKAGE )); then
    PKG="$DEST/appliance-logs-$RHOST-$STAMP.tar.gz"
    # The remote side builds a staging tree and streams it back as tar.gz on stdout; everything
    # it runs is unprivileged and read-only. $1 = include Pi-hole logs (0/1).
    if ! rssh "bash -s -- $PIHOLE_LOGS" > "$PKG" 2>"$STAGE/package.err" <<'REMOTE'
set -u
PIHOLE_LOGS=${1:-0}
T=$(mktemp -d /tmp/ke-collect.XXXXXX); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/logs"
{
    echo "# host-info — collected $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname) by collect-appliance-logs.sh"
    sec() { printf '\n--- %s ---\n' "$*"; }
    sec "identity"; hostname; uname -a
    . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}"
    tr -d '\0' </proc/device-tree/model 2>/dev/null; echo
    sec "uptime / load"; uptime; cat /proc/loadavg
    sec "kernel cmdline"; cat /proc/cmdline
    sec "storage"; findmnt -no SOURCE,FSTYPE,OPTIONS /; df -h / /boot/firmware 2>/dev/null
    d=/sys/block/mmcblk0
    if [[ -d $d ]]; then
        echo "card: $(cat $d/device/name 2>/dev/null) manfid=$(cat $d/device/manfid 2>/dev/null) oemid=$(cat $d/device/oemid 2>/dev/null) date=$(cat $d/device/date 2>/dev/null) serial=$(cat $d/device/serial 2>/dev/null)"
        read -r _ _ _ _ _ _ wsect _ < $d/stat 2>/dev/null && echo "sectors written since boot: $wsect (= $(( wsect / 2048 )) MiB)"
    fi
    for e in /sys/fs/ext4/*/errors_count; do [[ -r $e ]] && echo "$(basename "$(dirname "$e")") ext4 errors_count=$(cat "$e")"; done
    journalctl -k -b -q --no-pager 2>/dev/null | grep -m2 -E 'mmc0: new|mmcblk0: mmc0' || true
    sec "memory"; free -m
    sec "network"; ip -br link; ip -br addr
    sec "failed units"; systemctl --failed --no-legend --no-pager 2>/dev/null || true
    sec "timers"; systemctl list-timers --all --no-pager 'dns-*' 'net-*' 'power-*' 'pihole-*' 'apt-*' 'fstrim*' 2>/dev/null || true
    sec "services (state, restarts, since)"
    for u in pihole-FTL unbound avahi-daemon systemd-resolved systemd-timesyncd ssh cron; do
        printf '%-18s %s\n' "$u" "$(systemctl show "$u" -p ActiveState,SubState,NRestarts,ActiveEnterTimestamp --value 2>/dev/null | paste -sd' ')"
    done
    sec "versions"; pihole-FTL --version 2>/dev/null | head -3 || true; unbound -V 2>/dev/null | head -1 || true
    echo "unbound dpkg diversions: $(dpkg-divert --list 2>/dev/null | grep -c unbound)"
    sec "journal + logs"; journalctl --disk-usage 2>/dev/null || true
    ls -la /var/log/*.log* 2>/dev/null; ls -la /var/log/pihole/ 2>/dev/null || true
    du -sh /etc/pihole/pihole-FTL.db /etc/pihole/gravity.db 2>&1 || true
    sec "power / thermal (vcgencmd needs group video)"
    vcgencmd get_throttled 2>/dev/null || echo "vcgencmd: n/a"; vcgencmd measure_temp 2>/dev/null || true
    for h in /sys/class/hwmon/hwmon*; do
        [[ -r $h/name && -r $h/temp1_input ]] && echo "$(cat "$h/name") $(( $(cat "$h/temp1_input") / 1000 ))'C"
    done
    sec "apt history (tail)"; tail -n 60 /var/log/apt/history.log 2>/dev/null || echo "(not readable or absent)"
    sec "this boot: warnings and errors (last 40)"; journalctl -b -p warning -q --no-pager 2>/dev/null | tail -n 40 || true
} > "$T/host-info.txt" 2>&1
for f in /var/log/dns-health.log /var/log/dns-health.log.1 /var/log/net-snapshot.log /var/log/net-snapshot.log.1 \
         /var/log/power-report.log /var/log/power-report.log.1; do
    [[ -r "$f" ]] && cp -p "$f" "$T/logs/" 2>/dev/null
done
if [[ "$PIHOLE_LOGS" == 1 ]]; then
    for f in /var/log/pihole/FTL.log /var/log/pihole/webserver.log; do [[ -r "$f" ]] && cp -p "$f" "$T/logs/" 2>/dev/null; done
fi
tar -C "$T" -czf - .
REMOTE
    then
        rm -f "$PKG"; PKG=""; warn "package failed: $(tr '\n' ' ' < "$STAGE/package.err" | cut -c1-160)"
    elif ! gzip -t "$PKG" 2>/dev/null; then
        rm -f "$PKG"; PKG=""; warn "package is not a valid gzip stream: $(tr '\n' ' ' < "$STAGE/package.err" | cut -c1-160)"
    else
        mkdir -p "$STAGE/pkg" && tar -xzf "$PKG" -C "$STAGE/pkg"
        note "package: $(stat -c%s "$PKG") bytes — $(cd "$STAGE/pkg" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
    fi
fi

# ---------------------------------------------------------------- unbound cache dump
DUMP=""
if (( DO_DUMP )); then
    DUMP="$DEST/dns-cache-as-of-$DUMP_STAMP.txt"
    if rssh 'sudo -n /usr/sbin/unbound-control -c /etc/unbound/unbound.conf dump_cache' > "$DUMP" 2>"$STAGE/dump.err" \
       && grep -q '^START_RRSET_CACHE' "$DUMP"; then
        note "cache dump: $(wc -l < "$DUMP") lines ($(grep -c '^;rrset' "$DUMP") rrsets, $(grep -c '^msg ' "$DUMP") messages)"
    else
        rm -f "$DUMP"; DUMP=""
        warn "cache dump skipped: $(tr '\n' ' ' < "$STAGE/dump.err" | cut -c1-140) — grant NOPASSWD for that one command (see --help)"
    fi
fi

# ---------------------------------------------------------------- review
HI="$STAGE/pkg/host-info.txt"; LOGS="$STAGE/pkg/logs"
cnt() { grep -c -E "$1" "$2" 2>/dev/null || true; }   # grep -c prints 0 and exits 1 on no match
echo
echo "===== $RHOST review ($STAMP) ====="
if [[ -f "$HI" ]]; then
    sed -n '/^--- identity ---/,/^--- uptime/p' "$HI" | sed -n '2,3p;5p' | sed 's/^/  /'
    sed -n '/^--- uptime/,+1p' "$HI" | tail -1 | sed 's/^/  /'
    grep -m1 -E '^card:' "$HI" | sed 's/^/  /' || true
    grep -m1 -E 'sectors written' "$HI" | sed 's/^/  /' || true
    failed=$(sed -n '/^--- failed units ---/,/^--- timers/p' "$HI" | sed '1d;$d' | grep -c . || true)
    echo "  failed units: $failed"
fi
if [[ -n "$JOURNAL" ]]; then
    echo "  journal: boots=$(cnt 'Booting Linux' "$JOURNAL") unit-failures=$(cnt 'Failed with result' "$JOURNAL") under-voltage/throttle=$(cnt 'under-voltage|throttl' "$JOURNAL") health ✗=$(cnt '✗' "$JOURNAL") ⚠=$(cnt '⚠' "$JOURNAL") ssh password-logins=$(cnt 'Accepted password' "$JOURNAL") failed-passwords=$(cnt 'Failed password' "$JOURNAL")"
fi
if [[ -f "$LOGS/dns-health.log" ]]; then
    echo "  health: $(grep -E 'DNS health check completed' "$LOGS/dns-health.log" | tail -1)"
    grep -E '✗|⚠' "$LOGS/dns-health.log" | tail -5 | sed 's/^/    /' || true
fi
if [[ -f "$LOGS/power-report.log" ]]; then
    echo "  power:  $(grep '^trend ' "$LOGS/power-report.log" | tail -1 || echo 'no trend records')"
    grep '^trend ' "$LOGS/power-report.log" | awk '{for(i=2;i<=NF;i++){split($i,kv,"="); if(kv[1]=="est_w") e+=kv[2]; if(kv[1]=="soc_c") t+=kv[2]}; n++} END{if(n) printf "          %d runs: mean est-input %.3f W (%.2f kWh/yr), mean SoC %.1f C\n", n, e/n, e/n*8.76, t/n}'
fi
if [[ -f "$LOGS/net-snapshot.log" ]]; then
    first=$(grep '^snapshot ' "$LOGS/net-snapshot.log" | head -1 || true); last=$(grep '^snapshot ' "$LOGS/net-snapshot.log" | tail -1 || true)
    if [[ -n "$last" ]]; then
        echo "  net:    $last"
        [[ "$first" != "$last" ]] && echo "   since: $first"
    else
        echo "  net:    no snapshot records yet (appliance predates --journal-summary)"
    fi
fi
echo "  files:"
for f in "$JOURNAL" "$DUMP" "$PKG"; do [[ -n "$f" ]] && printf '    %9d  %s\n' "$(stat -c%s "$f")" "$f"; done
if (( ${#WARNINGS[@]} )); then
    echo "  warnings:"; printf '    %s\n' "${WARNINGS[@]}"
fi
