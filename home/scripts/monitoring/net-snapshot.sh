#!/bin/bash
# net-snapshot.sh — periodic kernel network-stats snapshot for the weekly review.
# Read-only: dumps nstat (IP/TCP/UDP/ICMP SNMP counters) + ss (socket summary and
# listeners). Changes nothing. Paired with net-snapshot.timer (see etc/systemd/system/).
#
# Usage:
#   ./net-snapshot.sh            # DEFAULT: nstat shows only counters > 0 (compact)
#   ./net-snapshot.sh --full     # nstat shows ALL counters, including zeros
#   ./net-snapshot.sh --help
#
# Diff a week:  compare two snapshots to spot floods, listen-queue drops, retransmit
#               storms, or unexpected new listeners.
#
# nstat flags: -a absolute values, -s do NOT touch the shared history file (so this
#              won't disturb an interactive `nstat` you run by hand), -z include zeros.
#              Default here omits -z, so nstat prints only non-zero counters.

set -euo pipefail

FULL=0
case "${1:-}" in
    ""|--nonzero|-n)  FULL=0 ;;
    -f|--full|full)   FULL=1 ;;
    -h|--help)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *)
        echo "net-snapshot.sh: unknown argument '$1' (use --full or --help)" >&2
        exit 2 ;;
esac
# -z (include zeros) only when --full is requested; default = non-zero counters only.
if (( FULL )); then NSTAT_FLAGS="-asz"; else NSTAT_FLAGS="-as"; fi

LOG_FILE="/var/log/net-snapshot.log"
# Self-rotate: cap the local copy (journald holds the primary via the service unit).
LOG_MAX_BYTES=524288   # 512 KiB, then keep one previous generation
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
TS=$(date '+%Y-%m-%d %H:%M:%S')

emit() { echo "$*" | tee -a "$LOG_FILE" >/dev/null; echo "$*"; }

emit "===== net-snapshot $TS ($( ((FULL)) && echo 'full/all counters' || echo 'non-zero counters only' )) ====="

emit "--- nstat $NSTAT_FLAGS (absolute SNMP counters; retrans/drops/overflows tell the story) ---"
if command -v nstat >/dev/null 2>&1; then
    nstat $NSTAT_FLAGS 2>/dev/null | tee -a "$LOG_FILE"
else
    emit "nstat not installed (package: iproute2)"
fi

emit "--- ss -s (socket summary) ---"
ss -s 2>/dev/null | tee -a "$LOG_FILE" || true

emit "--- ss listeners (tcp/udp, with process) ---"
ss -tulpnH 2>/dev/null | tee -a "$LOG_FILE" || true

emit "--- ss established TCP (who is connected) ---"
ss -tanH state established 2>/dev/null | tee -a "$LOG_FILE" || true

# Optional extras (uncomment if the tools are installed / a firewall uses conntrack):
# emit "--- conntrack flow count (needs conntrack-tools + nf_conntrack) ---"
# command -v conntrack >/dev/null && conntrack -C 2>/dev/null | tee -a "$LOG_FILE" || true
# emit "--- recent martian/redirect kernel signals (needs 60-net-observe.conf) ---"
# journalctl -k --since "1 hour ago" 2>/dev/null | grep -iE 'martian|redirect' | tail -20 | tee -a "$LOG_FILE" || true

emit "===== end net-snapshot ====="
