#!/bin/bash
# ke-maintenance.sh — monthly device-maintenance bundle for an unmonitored appliance.
# Read-only against the system (its own log, and config backups it writes, aside):
#   1. SD surface read-scrub: read the whole boot medium at idle IO priority so the
#      card's controller touches every cell; failing regions surface as read errors
#      years before normal traffic would find them.
#   2. SQLite quick_check on Pi-hole's gravity and FTL databases (silent-corruption canary).
#   3. journalctl --verify over the persistent journal files.
#   4. Pi-hole Teleporter configuration backup into /var/lib/ke-maintenance (keep 6).
# Paired with ke-maintenance.timer (monthly). See layer/ke-25-monitor.yaml.
#
# Usage:
#   sudo ./ke-maintenance.sh                    # full run, report to terminal + log
#   sudo ./ke-maintenance.sh --journal-summary  # body to the log only; print one "maintenance" record
#   sudo ./ke-maintenance.sh --no-scrub         # skip the ~1 h surface read (tests)
#   ./ke-maintenance.sh --help
#
# Record: maintenance ts=<ISO> scrub_mib= scrub_s= scrub_err= db_gravity= db_ftl=
#         journal_fail= teleporter= kept=
#         (value "skip" = task not run / tool unavailable; FAIL = task found a problem)
#
# Log: /var/log/ke-maintenance.log, self-rotates at 2 MiB with one previous generation.
set -euo pipefail

JOURNAL_SUMMARY=0; DO_SCRUB=1
while (( $# )); do
    case "$1" in
        -j|--journal-summary) JOURNAL_SUMMARY=1 ;;
        --no-scrub)           DO_SCRUB=0 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ke-maintenance.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

LOG_FILE="${LOG_FILE:-/var/log/ke-maintenance.log}"   # env override is for tests only
LOG_MAX_BYTES=2097152
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
    echo "ke-maintenance.sh: $LOG_FILE not writable, output to terminal only" >&2
    LOG_FILE=/dev/null
    JOURNAL_SUMMARY=0
fi
TS=$(date '+%Y-%m-%d %H:%M:%S')

if (( JOURNAL_SUMMARY )); then body() { cat >> "$LOG_FILE"; }; else body() { tee -a "$LOG_FILE"; }; fi
emit()   { echo "$*" | body; }
record() { echo "$*" | tee -a "$LOG_FILE"; }

emit "===== ke-maintenance $TS ====="

# ---- 1. SD surface read-scrub -------------------------------------------------
SCRUB_MIB=skip; SCRUB_S=skip; SCRUB_ERR=skip
if (( DO_SCRUB )); then
    ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
    PK=$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null | head -1 || true)
    if [[ -n "$PK" && -r "/dev/$PK" ]]; then
        ERR_BEFORE=$(dmesg 2>/dev/null | grep -ciE 'mmc[0-9]+:.*(error|fail)|blk_update_request.*I/O error' || true)
        emit "--- read-scrub of /dev/$PK (nice/idle; ~1 h on this card) ---"
        T0=$SECONDS
        if nice -n19 ionice -c3 dd if="/dev/$PK" of=/dev/null bs=4M iflag=direct 2> >(tail -1 | body); then
            SCRUB_ERR=0
        else
            SCRUB_ERR=FAIL
        fi
        SCRUB_S=$(( SECONDS - T0 ))
        SCRUB_MIB=$(( $(blockdev --getsize64 "/dev/$PK" 2>/dev/null || echo 0) / 1048576 ))
        ERR_AFTER=$(dmesg 2>/dev/null | grep -ciE 'mmc[0-9]+:.*(error|fail)|blk_update_request.*I/O error' || true)
        if [[ "$SCRUB_ERR" == "0" ]] && (( ERR_AFTER > ERR_BEFORE )); then
            SCRUB_ERR=$(( ERR_AFTER - ERR_BEFORE ))
            emit "WARNING: $SCRUB_ERR new kernel I/O error lines during the scrub"
        fi
    else
        emit "read-scrub skipped: cannot resolve or read the boot medium (root needed)"
    fi
else
    emit "read-scrub skipped (--no-scrub)"
fi

# ---- 2. database integrity ----------------------------------------------------
db_check() {  # db_check <path> -> ok | FAIL | skip
    local db=$1 out
    if [[ ! -r "$db" ]]; then echo skip; return; fi
    if ! command -v pihole-FTL >/dev/null 2>&1; then echo skip; return; fi
    out=$(pihole-FTL sqlite3 "$db" '.timeout 5000' 'PRAGMA quick_check;' 2>&1 | tail -1 || true)
    [[ "$out" == "ok" ]] && echo ok || echo FAIL
}
DB_GRAVITY=$(db_check /etc/pihole/gravity.db)
DB_FTL=$(db_check /etc/pihole/pihole-FTL.db)
emit "--- sqlite quick_check: gravity.db=$DB_GRAVITY pihole-FTL.db=$DB_FTL ---"

# ---- 3. journal verify --------------------------------------------------------
JOURNAL_FAIL=skip
if command -v journalctl >/dev/null 2>&1; then
    JV=$(journalctl --verify 2>&1 || true)
    JOURNAL_FAIL=$(printf '%s\n' "$JV" | grep -c '^FAIL' || true)
    emit "--- journalctl --verify: $JOURNAL_FAIL failing file(s) ---"
    printf '%s\n' "$JV" | grep '^FAIL' | body || true
fi

# ---- 4. teleporter configuration backup ---------------------------------------
TELEPORTER=skip; KEPT=skip
BACKUP_DIR="${BACKUP_DIR:-/var/lib/ke-maintenance}"
if command -v pihole-FTL >/dev/null 2>&1 && install -d -m 0750 "$BACKUP_DIR" 2>/dev/null; then
    if ( cd "$BACKUP_DIR" && pihole-FTL --teleporter >/dev/null 2>&1 ); then
        TELEPORTER=$(ls -t "$BACKUP_DIR"/*teleporter*.zip 2>/dev/null | head -1 | xargs -r basename)
        # keep the 6 newest
        ls -t "$BACKUP_DIR"/*teleporter*.zip 2>/dev/null | tail -n +7 | xargs -r rm -f
        KEPT=$(ls "$BACKUP_DIR"/*teleporter*.zip 2>/dev/null | wc -l)
    else
        TELEPORTER=FAIL
    fi
fi
emit "--- teleporter: $TELEPORTER (kept $KEPT) ---"

record "maintenance ts=$(date '+%Y-%m-%dT%H:%M:%S') scrub_mib=$SCRUB_MIB scrub_s=$SCRUB_S scrub_err=$SCRUB_ERR db_gravity=$DB_GRAVITY db_ftl=$DB_FTL journal_fail=$JOURNAL_FAIL teleporter=$TELEPORTER kept=$KEPT"
