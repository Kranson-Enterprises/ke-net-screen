#!/bin/bash
# net-snapshot.sh — periodic kernel network-stats snapshot for the weekly review.
# Read-only: dumps nstat (IP/TCP/UDP/ICMP SNMP counters) + ss (socket summary and
# listeners) and ends with one grep-able "snapshot" record. Changes nothing.
# Paired with net-snapshot.timer (see etc/systemd/system/).
#
# Usage:
#   ./net-snapshot.sh                    # DEFAULT: nstat shows only counters > 0 (compact)
#   ./net-snapshot.sh --full             # nstat shows ALL counters, including zeros
#   ./net-snapshot.sh --journal-summary  # body to the log file only; print just the "snapshot" record
#                                        # (the service unit runs this way, so journald gets one line per run)
#   ./net-snapshot.sh --help
#
# Record: snapshot ts=<ISO> ip_in= udp_in= udp_noport= udp_in_err= udp_rcvbuf_err= tcp_pass=
#         tcp_act= tcp_retrans= tcp_listen_drop= tcp_listen_overflow= v6_noroute= ra_in=
#         listeners= estab=
#         Counters are absolute since boot (nstat -a), so a week of load or loss is the
#         difference between two records:  grep '^snapshot ' /var/log/net-snapshot.log | sed -n '1p;$p'
#         A counter that nstat omits (zero, without -z) prints as 0.
#
# Log: /var/log/net-snapshot.log is the full record; self-rotates at 2 MiB (about two weeks
#      of hourly runs) with one previous generation kept. Runs by a user who cannot write
#      /var/log print to the terminal only.
#
# Diff a week:  compare two snapshots to spot floods, listen-queue drops, retransmit
#               storms, or unexpected new listeners.
# nstat flags:  -a absolute values, -s do NOT touch the shared history file (so this
#               won't disturb an interactive `nstat` you run by hand), -z include zeros.

set -euo pipefail

FULL=0; JOURNAL_SUMMARY=0
while (( $# )); do
    case "$1" in
        ""|--nonzero|-n)      FULL=0 ;;
        -f|--full|full)       FULL=1 ;;
        -j|--journal-summary) JOURNAL_SUMMARY=1 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "net-snapshot.sh: unknown argument '$1' (see --help)" >&2
            exit 2 ;;
    esac
    shift
done
# -z (include zeros) only when --full is requested; default = non-zero counters only.
if (( FULL )); then NSTAT_FLAGS="-asz"; else NSTAT_FLAGS="-as"; fi

LOG_FILE="${LOG_FILE:-/var/log/net-snapshot.log}"   # env override is for tests only
# Self-rotate: the file is the full record; cap it and keep one previous generation.
LOG_MAX_BYTES=2097152   # 2 MiB ≈ two weeks of hourly runs per generation
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
# Manual runs without write access to /var/log go to the terminal only.
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
    echo "net-snapshot.sh: $LOG_FILE not writable, output to terminal only" >&2
    LOG_FILE=/dev/null
    JOURNAL_SUMMARY=0      # nowhere else for the body to go
fi
TS=$(date '+%Y-%m-%d %H:%M:%S')

# Output plumbing. body: the report — file + stdout normally, file only with
# --journal-summary. record: the one-line snapshot — always file + stdout.
if (( JOURNAL_SUMMARY )); then body() { cat >> "$LOG_FILE"; }; else body() { tee -a "$LOG_FILE"; }; fi
emit()   { echo "$*" | body; }
record() { echo "$*" | tee -a "$LOG_FILE"; }

emit "===== net-snapshot $TS ($( ((FULL)) && echo 'full/all counters' || echo 'non-zero counters only' )) ====="

emit "--- nstat $NSTAT_FLAGS (absolute SNMP counters; retrans/drops/overflows tell the story) ---"
NSTAT_OUT=""
if command -v nstat >/dev/null 2>&1; then
    NSTAT_OUT=$(nstat $NSTAT_FLAGS 2>/dev/null || true)
    printf '%s\n' "$NSTAT_OUT" | body
else
    emit "nstat not installed (package: iproute2)"
fi

emit "--- ss -s (socket summary) ---"
ss -s 2>/dev/null | body || true

emit "--- ss listeners (tcp/udp, with process) ---"
LISTENERS=$(ss -tulpnH 2>/dev/null || true)
printf '%s\n' "$LISTENERS" | body

emit "--- ss established TCP (who is connected) ---"
ESTAB=$(ss -tanH state established 2>/dev/null || true)
printf '%s\n' "$ESTAB" | body

# Optional extras (uncomment if the tools are installed / a firewall uses conntrack):
# emit "--- conntrack flow count (needs conntrack-tools + nf_conntrack) ---"
# command -v conntrack >/dev/null && conntrack -C 2>/dev/null | body || true
# emit "--- recent martian/redirect kernel signals (needs 60-net-observe.conf) ---"
# journalctl -k --since "1 hour ago" 2>/dev/null | grep -iE 'martian|redirect' | tail -20 | body || true

# One grep-able record per run (see header). The only line journald sees under --journal-summary.
cnt() { local v; v=$(awk -v k="$1" '$1 == k { print $2; exit }' <<<"$NSTAT_OUT"); echo "${v:-0}"; }
n_listen=$(grep -c . <<<"$LISTENERS" || true)
n_estab=$(grep -c . <<<"$ESTAB" || true)
if [[ -n "$NSTAT_OUT" ]]; then
    RECORD=$(printf 'snapshot ts=%s ip_in=%s udp_in=%s udp_noport=%s udp_in_err=%s udp_rcvbuf_err=%s tcp_pass=%s tcp_act=%s tcp_retrans=%s tcp_listen_drop=%s tcp_listen_overflow=%s v6_noroute=%s ra_in=%s listeners=%s estab=%s' \
        "${TS// /T}" "$(cnt IpInReceives)" "$(cnt UdpInDatagrams)" "$(cnt UdpNoPorts)" "$(cnt UdpInErrors)" "$(cnt UdpRcvbufErrors)" \
        "$(cnt TcpPassiveOpens)" "$(cnt TcpActiveOpens)" "$(cnt TcpRetransSegs)" "$(cnt TcpExtListenDrops)" "$(cnt TcpExtListenOverflows)" \
        "$(cnt Ip6OutNoRoutes)" "$(cnt Icmp6InRouterAdvertisements)" "$n_listen" "$n_estab")
else
    RECORD="snapshot ts=${TS// /T} nstat=unavailable listeners=$n_listen estab=$n_estab"
fi
emit
record "$RECORD"
emit "===== end net-snapshot ====="
