#!/bin/bash
# schedule-reboot.sh — interactive scheduled-reboot management for the appliance.
# A deliberate, periodic reboot proves the full boot path still works while changes
# are fresh, instead of discovering boot breakage during a power outage in year three.
#
# Usage:  sudo ./schedule-reboot.sh                   interactive; the only mode that
#                                                     changes anything
#         ./schedule-reboot.sh --print CADENCE [DIR]  dry run: render the two unit files
#                                                     for CADENCE to stdout, or write them
#                                                     into DIR (never a systemd unit
#                                                     directory); no root, no tty
#         CADENCE = 1-6 as in the menu, or weekly | biweekly | monthly | quarterly |
#                   semiannual | yearly
#   scripts/pre-release-check.sh renders every cadence with --print and checks what systemd
#   would run, because these units are written on the device and no build check sees them.
#
# What it does, in order:
#   1. Shows the FULL existing schedule: /etc/crontab, /etc/cron.d/*, root crontab,
#      and systemd timers — so a reboot is never scheduled blind.
#   2. Shows the existing scheduled reboot (this tool's timer and any cron reboot line).
#   3. Offers a cadence: weekly, bi-weekly, monthly, quarterly, semi-annually, yearly —
#      or removal. Presents the exact change and asks before applying.
#
# Mechanism: a systemd timer (ke-scheduled-reboot.timer) at 05:10 — after the Sunday
#   gravity window (~03:04-04:32), after monthly ke-maintenance (1st 03:40 + <=25 min),
#   before cron.daily (06:25). Persistent=false ON PURPOSE: a persistent reboot timer
#   catches up at boot and can reboot-loop the box. Bi-weekly uses an ISO-week parity
#   guard (even weeks), since neither cron nor OnCalendar expresses "every 2 weeks".
# The reboot logs one journald line (tag ke-scheduled-reboot) before restarting.
set -euo pipefail

UNIT=ke-scheduled-reboot
TIMER_F=/etc/systemd/system/$UNIT.timer
SVC_F=/etc/systemd/system/$UNIT.service

usage() { sed -n '2,29p' "$0"; }

# Cadence table, shared by the menu and --print. Sets CAL, DESC and GUARD (bi-weekly only);
# returns 1 for an unknown selection.
set_cadence() {
    GUARD=""
    case "$1" in
        1|weekly)        CAL="Sun *-*-* 05:10"; DESC="weekly (Sunday)" ;;
        2|biweekly|bi-weekly)
                         CAL="Sun *-*-* 05:10"; DESC="bi-weekly (even ISO weeks, Sunday)"
           # This string lands in ExecStart=, where systemd expands %-specifiers (%V would
           # become /var/tmp) and ${...}; so: %% for a literal %, no braces, and %-V
           # (unpadded week) instead of bash-only 10# since the unit runs under dash.
           GUARD='/bin/sh -c '\''w=$(date +%%-V); if [ $((w %% 2)) -eq 0 ]; then logger -t ke-scheduled-reboot "bi-weekly reboot (ISO week $w)"; systemctl reboot; else logger -t ke-scheduled-reboot "odd ISO week $w: skipping"; fi'\' ;;
        3|monthly)       CAL="*-*-01 05:10"; DESC="monthly (1st)" ;;
        4|quarterly)     CAL="*-01,04,07,10-01 05:10"; DESC="quarterly (Jan/Apr/Jul/Oct 1st)" ;;
        5|semiannual|semi-annually)
                         CAL="*-01,07-01 05:10"; DESC="semi-annually (Jan/Jul 1st)" ;;
        6|yearly)        CAL="*-01-01 05:10"; DESC="yearly (Jan 1st)" ;;
        *) return 1 ;;
    esac
}

# The two unit files, shared by the installer and --print (both use set_cadence's values).
render_service() {
    local exec_line="/bin/sh -c 'logger -t $UNIT \"scheduled reboot ($DESC)\"; systemctl reboot'"
    if [[ -n "$GUARD" ]]; then exec_line="$GUARD"; fi
    cat <<EOF
# Written by schedule-reboot.sh $(date '+%Y-%m-%d %H:%M'). Cadence: $DESC
[Unit]
Description=Scheduled appliance reboot ($DESC)

[Service]
Type=oneshot
ExecStart=$exec_line
EOF
}
render_timer() {
    cat <<EOF
# Written by schedule-reboot.sh $(date '+%Y-%m-%d %H:%M'). Cadence: $DESC
[Unit]
Description=Scheduled appliance reboot ($DESC)

[Timer]
OnCalendar=$CAL
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    --print)
        (( $# == 2 || $# == 3 )) || { usage >&2; exit 2; }
        set_cadence "$2" || { echo "schedule-reboot.sh: unknown cadence '$2'" >&2; exit 2; }
        if (( $# == 2 )); then
            echo "# ===== $UNIT.service"; render_service
            echo; echo "# ===== $UNIT.timer"; render_timer
            exit 0
        fi
        OUT=$3
        [[ -d "$OUT" ]] || { echo "schedule-reboot.sh: no such directory: $OUT" >&2; exit 2; }
        for d in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system; do
            if [[ "$OUT" -ef "$d" ]]; then
                echo "schedule-reboot.sh: --print never installs; run without options to change $d" >&2
                exit 2
            fi
        done
        render_service > "$OUT/$UNIT.service"
        render_timer > "$OUT/$UNIT.timer"
        echo "wrote $OUT/$UNIT.service and $OUT/$UNIT.timer ($DESC)"
        exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

(( EUID == 0 )) || { echo "schedule-reboot.sh: needs root (sudo)" >&2; exit 2; }
[[ -t 0 ]] || { echo "schedule-reboot.sh: interactive; run from a terminal" >&2; exit 2; }

echo "===== existing schedule (know what you are rebooting around) ====="
echo "--- /etc/crontab:"
grep -vE '^\s*(#|$)' /etc/crontab 2>/dev/null | sed 's/^/    /' || true
echo "--- /etc/cron.d/*:"
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    entries=$(grep -vE '^\s*(#|$)' "$f" || true)
    [[ -n "$entries" ]] && { echo "    [$f]"; sed 's/^/      /' <<<"$entries"; }
done
echo "--- root crontab:"
crontab -l 2>/dev/null | grep -vE '^\s*(#|$)' | sed 's/^/    /' || echo "    (none)"
echo "--- systemd timers:"
systemctl list-timers --no-pager --all 2>/dev/null | sed 's/^/    /' | head -16

echo
echo "===== existing scheduled reboot ====="
if systemctl list-unit-files "$UNIT.timer" --no-legend 2>/dev/null | grep -q "$UNIT"; then
    echo "  $UNIT.timer: $(systemctl is-enabled "$UNIT.timer" 2>/dev/null || true), $(systemctl is-active "$UNIT.timer" 2>/dev/null || true)"
    grep -E 'OnCalendar|parity' "$TIMER_F" "$SVC_F" 2>/dev/null | sed 's/^/    /'
    systemctl list-timers "$UNIT.timer" --no-pager --no-legend 2>/dev/null | sed 's/^/    next: /'
else
    echo "  none from this tool"
fi
CRON_REBOOTS=$(grep -rlE '(^|[[:space:]])(shutdown|reboot|systemctl[[:space:]]+reboot)' /etc/cron.d/ /etc/crontab 2>/dev/null || true)
[[ -n "$CRON_REBOOTS" ]] && echo "  WARNING: cron files also mention reboot/shutdown: $CRON_REBOOTS"

echo
echo "===== choose a cadence (all at 05:10, see header for why) ====="
cat <<'EOM'
  1) weekly         (every Sunday)
  2) bi-weekly      (even ISO weeks, Sunday)
  3) monthly        (1st of the month)
  4) quarterly      (Jan/Apr/Jul/Oct 1st)
  5) semi-annually  (Jan/Jul 1st)
  6) yearly         (Jan 1st)
  0) remove the scheduled reboot
  q) quit without changes
EOM
read -r -p "selection: " SEL

case "$SEL" in
    [1-6]) set_cadence "$SEL" ;;
    0)
        if [[ -f "$TIMER_F" || -f "$SVC_F" ]]; then
            read -r -p "Remove $UNIT.timer and its service? [y/N]: " ans
            [[ "${ans,,}" =~ ^y ]] || { echo "unchanged"; exit 0; }
            systemctl disable --now "$UNIT.timer" 2>/dev/null || true
            rm -f "$TIMER_F" "$SVC_F"
            systemctl daemon-reload
            echo "removed; no scheduled reboot remains"
        else
            echo "nothing to remove"
        fi
        exit 0 ;;
    q|Q|"") echo "unchanged"; exit 0 ;;
    *) echo "unknown selection '$SEL'" >&2; exit 2 ;;
esac

echo
echo "===== proposed change ====="
echo "  cadence : $DESC"
echo "  trigger : OnCalendar=$CAL   (Persistent=false — never catches up at boot)"
[[ -n "$GUARD" ]] && echo "  guard   : even-ISO-week check in the service (bi-weekly)"
echo "  action  : one journald line (tag $UNIT), then systemctl reboot"
systemd-analyze calendar "$CAL" 2>/dev/null | sed 's/^/    /' | head -4 || true
read -r -p "Write and enable this schedule now? [y/N]: " ans
[[ "${ans,,}" =~ ^y ]] || { echo "unchanged"; exit 0; }

render_service > "$SVC_F"
render_timer > "$TIMER_F"
systemctl daemon-reload
systemctl enable --now "$UNIT.timer"
echo
echo "===== result ====="
systemctl list-timers "$UNIT.timer" --no-pager | sed 's/^/  /'
echo "  Remove or change later: rerun this script."
