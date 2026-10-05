#!/bin/bash
# eeprom-update.sh — Raspberry Pi bootloader EEPROM: show what is installed against what the
# image's rpi-eeprom package offers, and stage an update only when asked. The boot-time
# service (rpi-eeprom-update -s -a) applies critical minimums only, so a board can sit on a
# months-old bootloader while reporting "up to date"; this closes that gap deliberately.
#
# Usage:
#   ./eeprom-update.sh                        # DEFAULT: installed vs latest, channel, pending state (read-only)
#   sudo ./eeprom-update.sh --apply           # stage the channel's latest image (rpi-eeprom-update -a), then ask to reboot
#   sudo ./eeprom-update.sh --apply --reboot  # stage and reboot without asking (unattended)
#   sudo ./eeprom-update.sh --clear           # remove a staged, not yet applied update from the boot partition
#   ./eeprom-update.sh --help
#
# How it applies: rpi-eeprom-update writes recovery.bin + pieeprom.upd/.sig to the boot
#   partition; on the next boot the ROM runs recovery.bin, flashes the EEPROM (a few seconds,
#   green LED blinks, do NOT cut power), renames it recovery.000 and resets. The bootloader
#   configuration (boot order etc.) is kept. Verify afterwards: ./eeprom-update.sh shows
#   CURRENT = LATEST.
# Channel: FIRMWARE_RELEASE_STATUS in /etc/default/rpi-eeprom-update ("default" on this image;
#   never changed here). Images: /usr/lib/firmware/raspberrypi/bootloader-2712/<channel>/.
# Log: /var/log/eeprom-update.log (self-rotates at 256 KiB, one previous generation kept).
# Exit: 0 up to date / action done, 1 update available (read-only mode), 2 usage, 3 error.

set -euo pipefail

MODE=show; REBOOT=0
while (( $# )); do
    case "$1" in
        --apply)   MODE=apply ;;
        --reboot)  REBOOT=1 ;;
        --clear)   MODE=clear ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "eeprom-update.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done
command -v rpi-eeprom-update >/dev/null 2>&1 || { echo "eeprom-update.sh: rpi-eeprom-update not found (package rpi-eeprom)" >&2; exit 3; }

LOG_FILE="${LOG_FILE:-/var/log/eeprom-update.log}"   # env override is for tests only
LOG_MAX_BYTES=262144   # 256 KiB, then keep one previous generation
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then LOG_FILE=/dev/null; fi
TS=$(date '+%Y-%m-%d %H:%M:%S')
emit() { echo "$*" | tee -a "$LOG_FILE"; }
die()  { emit "eeprom-update.sh: $*" >&2; exit 3; }

# Boot partition as the tool sees it (BOOTFS override honoured, default /boot/firmware).
BOOTFS=$( . /etc/default/rpi-eeprom-update 2>/dev/null; echo "${BOOTFS:-/boot/firmware}" )

# rpi-eeprom-update exits 0 when up to date and 1 when an update is available; both are answers.
STATUS_OUT=$(rpi-eeprom-update 2>&1) && STATUS_RC=0 || STATUS_RC=$?
(( STATUS_RC <= 1 )) || die "rpi-eeprom-update failed (exit $STATUS_RC): $(tr '\n' ' ' <<<"$STATUS_OUT" | cut -c1-200)"
CUR=$(sed -n 's/.*CURRENT:.*(\([0-9]\+\)).*/\1/p' <<<"$STATUS_OUT" | head -1)
LATEST=$(sed -n 's/.*LATEST:.*(\([0-9]\+\)).*/\1/p' <<<"$STATUS_OUT" | head -1)
CHANNEL=$(sed -n 's/.*RELEASE: \([A-Za-z0-9_-]\+\).*/\1/p' <<<"$STATUS_OUT" | head -1)
[[ -n "$CUR" && -n "$LATEST" ]] || die "could not parse CURRENT/LATEST from: $(tr '\n' ' ' <<<"$STATUS_OUT" | cut -c1-200)"
CUR_D=$(date -u -d "@$CUR" '+%Y-%m-%d'); LATEST_D=$(date -u -d "@$LATEST" '+%Y-%m-%d')
PENDING=0; [[ -f "$BOOTFS/pieeprom.upd" || -f "$BOOTFS/recovery.bin" ]] && PENDING=1
MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown model")

emit "===== eeprom-update $TS — $MODEL ====="
emit "  installed   $CUR_D ($CUR)"
emit "  latest      $LATEST_D ($LATEST)   channel: ${CHANNEL:-unknown}"
[[ -f "$BOOTFS/recovery.000" ]] && emit "  note        recovery.000 present: a previous update applied successfully (file is inert)"
if (( PENDING )); then
    emit "  state       STAGED, pending reboot ($BOOTFS/pieeprom.upd) — reboot to flash, or --clear to withdraw"
elif (( CUR >= LATEST )); then
    emit "  state       up to date"
else
    emit "  state       UPDATE AVAILABLE: $CUR_D -> $LATEST_D (sudo $(basename "$0") --apply)"
fi

case "$MODE" in
    show)
        (( PENDING || CUR >= LATEST )) && exit 0 || exit 1 ;;
    clear)
        (( EUID == 0 )) || die "--clear needs root (sudo)"
        (( PENDING )) || { emit "  nothing staged; nothing to clear"; exit 0; }
        rpi-eeprom-update -r 2>&1 | tee -a "$LOG_FILE"
        emit "  cleared staged update files from $BOOTFS"
        exit 0 ;;
    apply)
        (( EUID == 0 )) || die "--apply needs root (sudo)"
        (( PENDING )) && die "an update is already staged; reboot to apply it, or --clear first"
        (( CUR < LATEST )) || { emit "  already at the channel's latest; nothing staged"; exit 0; }
        emit "--- staging $LATEST_D from channel ${CHANNEL:-unknown} (rpi-eeprom-update -a) ---"
        rpi-eeprom-update -a 2>&1 | tee -a "$LOG_FILE"
        [[ -f "$BOOTFS/pieeprom.upd" ]] || die "rpi-eeprom-update -a finished but $BOOTFS/pieeprom.upd is missing"
        emit "  staged OK: $BOOTFS/pieeprom.upd $(stat -c%s "$BOOTFS/pieeprom.upd") bytes; the EEPROM is flashed on the next boot"
        if (( REBOOT )); then
            emit "  rebooting now (--reboot)"
            systemctl reboot
        elif [[ -t 0 ]]; then
            read -r -p "  Reboot now to flash the bootloader? [y/N]: " ans
            if [[ "${ans,,}" =~ ^y ]]; then emit "  rebooting"; systemctl reboot; else emit "  not rebooting; the update applies at the next boot"; fi
        else
            emit "  not a terminal; the update applies at the next boot (or rerun with --reboot)"
        fi
        exit 0 ;;
esac
