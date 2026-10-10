#!/bin/bash
# wpad-block.sh — turn the Pi-hole regex that stops Web Proxy Auto-Discovery lookups on or
# off at run time, with a backup of the domain lists before every change and a restore path.
# WPAD: Windows and "auto-detect proxy" browsers resolve wpad.<dns-suffix>; whoever answers
# can hand the client a proxy script. Pi-hole answering the regex locally (0.0.0.0) also
# stops the client's LLMNR/NetBIOS fallback, which an NXDOMAIN would not.
#
# Usage:
#   ./wpad-block.sh                       # status: entry present/enabled? all regex deny entries; backups
#   sudo ./wpad-block.sh --on             # back up, add (or re-enable) the entry, reload FTL lists
#   sudo ./wpad-block.sh --off            # back up, remove the entry this script/the image added, reload
#   sudo ./wpad-block.sh --off --force    # remove the entry even if someone else added it
#   sudo ./wpad-block.sh --restore [FILE] # restore domainlist (+ group links) from a backup, latest if no FILE
#   ./wpad-block.sh --list-backups
#   ./wpad-block.sh --regex 'PATTERN' ... # manage another regex deny pattern instead of ^wpad\.
#   ./wpad-block.sh --help
#
# Backups: ~/pihole-backups/domainlist-<YYYYmmdd-HHMMSS>-<pid>.sql in the invoking user's
#   home (SUDO_USER aware): SQL INSERT statements for the whole domainlist table and its
#   group links, taken before --on, --off and --restore. Nothing is pruned automatically.
# Scope: only Pi-hole's domainlist (exact/regex allow and deny entries). Adlists, groups,
#   clients and settings are untouched. Changes apply with `pihole reloadlists` (no cache flush).
# Exit: 0 ok / entry active in status, 1 entry absent in status, 2 usage, 3 error.

set -euo pipefail

DEFAULT_REGEX='^wpad\.'
REGEX="$DEFAULT_REGEX"; MODE=status; FORCE=0; RESTORE_FILE=""
while (( $# )); do
    case "$1" in
        --on)            MODE=on ;;
        --off)           MODE=off ;;
        --force)         FORCE=1 ;;
        --restore)       MODE=restore; if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then RESTORE_FILE=$2; shift; fi ;;
        --list-backups)  MODE=list ;;
        --regex)         REGEX=${2:?--regex needs a pattern}; shift ;;
        -h|--help)       sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "wpad-block.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
# sqlite shell: Pi-hole ships one inside pihole-FTL; a system sqlite3 also works (tests).
if [[ -z "${SQLITE_CMD:-}" ]]; then
    if command -v pihole-FTL >/dev/null 2>&1; then SQLITE_CMD="pihole-FTL sqlite3"
    elif command -v sqlite3 >/dev/null 2>&1; then SQLITE_CMD="sqlite3"
    else echo "wpad-block.sh: no sqlite shell (pihole-FTL or sqlite3)" >&2; exit 3; fi
fi
RELOAD_CMD="${RELOAD_CMD:-pihole reloadlists}"
HOME_DIR=$HOME
if [[ -n "${SUDO_USER:-}" ]]; then HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
BACKUP_DIR="${BACKUP_DIR:-$HOME_DIR/pihole-backups}"
MARK="ke wpad-block"                       # comment marker for entries this script adds
IMAGE_MARK="ke-net-screen image default"   # entries the first-boot import added
REGEX_DENY=3

die()  { echo "wpad-block.sh: $*" >&2; exit 3; }
sql()  { $SQLITE_CMD "$GRAVITY_DB" "$@"; }
# Root is what writing /etc/pihole/gravity.db and reloading FTL normally take; a database the
# caller can already write (tests, custom GRAVITY_DB) needs none.
need_root() { (( EUID == 0 )) || [[ -w "$GRAVITY_DB" ]] || die "$1 needs root (sudo)"; }
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

[[ -r "$GRAVITY_DB" ]] || die "cannot read $GRAVITY_DB"
Q=$(sql_quote "$REGEX")

backup() {
    install -d -m 0700 "$BACKUP_DIR"
    local f="$BACKUP_DIR/domainlist-$(date +%Y%m%d-%H%M%S)-$$.sql"
    while [[ -e "$f" ]]; do f="${f%.sql}x.sql"; done
    {
        echo "-- wpad-block.sh backup of $GRAVITY_DB domainlist on $(hostname) $(date -Is)"
        sql ".mode insert domainlist" "SELECT * FROM domainlist ORDER BY id;"
        sql ".mode insert domainlist_by_group" "SELECT * FROM domainlist_by_group ORDER BY domainlist_id, group_id;"
    } > "$f"
    chmod 0600 "$f"
    if [[ -n "${SUDO_USER:-}" ]]; then chown "$SUDO_USER" "$BACKUP_DIR" "$f" 2>/dev/null || true; fi
    echo "  backup: $f ($(grep -c '^INSERT INTO domainlist ' "$f" || true) domainlist rows)"
}
reload() {
    echo "  reloading FTL lists: $RELOAD_CMD"
    if $RELOAD_CMD >/dev/null 2>&1; then echo "  reloaded"; else echo "  !! reload failed; run '$RELOAD_CMD' by hand" >&2; fi
}
entry() { sql "SELECT id || '|' || enabled || '|' || COALESCE(comment,'') FROM domainlist WHERE type = $REGEX_DENY AND domain = '$Q' LIMIT 1;"; }

case "$MODE" in
    status)
        echo "===== wpad-block status — $GRAVITY_DB ====="
        row=$(entry)
        if [[ -n "$row" ]]; then
            IFS='|' read -r id en cm <<<"$row"
            echo "  $REGEX : present (id $id, enabled=$en${cm:+, comment: $cm})"
        else
            echo "  $REGEX : absent"
        fi
        echo "  all regex deny entries:"
        sql "SELECT '    [' || CASE enabled WHEN 1 THEN 'on ' ELSE 'off' END || '] ' || domain || '   ' || COALESCE(comment,'') FROM domainlist WHERE type = $REGEX_DENY ORDER BY id;" | sed 's/ *$//'
        n=$(find "$BACKUP_DIR" -maxdepth 1 -name 'domainlist-*.sql' 2>/dev/null | wc -l)
        echo "  backups: $n in $BACKUP_DIR"
        if [[ -n "$row" && "${row#*|}" == 1* ]]; then exit 0; else exit 1; fi ;;
    list)
        ls -la "$BACKUP_DIR"/domainlist-*.sql 2>/dev/null || echo "no backups in $BACKUP_DIR" ;;
    on)
        need_root "--on"; backup
        row=$(entry)
        if [[ -z "$row" ]]; then
            sql "INSERT INTO domainlist (type, domain, enabled, comment) VALUES ($REGEX_DENY, '$Q', 1, '$MARK');"
            echo "  added regex deny: $REGEX"
        elif [[ "${row#*|}" == 0* ]]; then
            sql "UPDATE domainlist SET enabled = 1 WHERE type = $REGEX_DENY AND domain = '$Q';"
            echo "  re-enabled regex deny: $REGEX"
        else
            echo "  already present and enabled: $REGEX"
        fi
        reload ;;
    off)
        need_root "--off"
        row=$(entry)
        if [[ -z "$row" ]]; then echo "  not present: $REGEX (nothing to do)"; exit 0; fi
        cm=${row#*|}; cm=${cm#*|}
        if [[ "$cm" != *"$MARK"* && "$cm" != *"$IMAGE_MARK"* && $FORCE -eq 0 ]]; then
            die "'$REGEX' exists but was added by someone else (comment: '${cm:-none}'); use --off --force to remove it anyway"
        fi
        backup
        sql "DELETE FROM domainlist WHERE type = $REGEX_DENY AND domain = '$Q';"
        echo "  removed regex deny: $REGEX"
        reload ;;
    restore)
        need_root "--restore"
        f=$RESTORE_FILE
        if [[ -z "$f" ]]; then f=$(ls -1t "$BACKUP_DIR"/domainlist-*.sql 2>/dev/null | head -1 || true); fi
        [[ -n "$f" && -r "$f" ]] || die "no backup to restore (looked in $BACKUP_DIR)"
        grep -q '^INSERT INTO domainlist ' "$f" || die "$f does not look like a wpad-block backup"
        src=$(mktemp); trap 'rm -f "$src" "$src.sql"' EXIT
        cp "$f" "$src"       # copy first; the pre-restore backup below gets its own name anyway
        backup               # the state being replaced is itself kept
        # Delete triggers drop group links; the insert trigger re-adds group 0 for every row,
        # then the saved links restore any other group assignments.
        {
            echo "BEGIN;"
            echo "DELETE FROM domainlist;"
            grep '^INSERT INTO domainlist ' "$src" | sed 's/^INSERT INTO domainlist /INSERT OR IGNORE INTO domainlist /' || true
            grep '^INSERT INTO domainlist_by_group ' "$src" | sed 's/^INSERT INTO domainlist_by_group /INSERT OR IGNORE INTO domainlist_by_group /' || true
            echo "COMMIT;"
        } > "$src.sql"
        $SQLITE_CMD "$GRAVITY_DB" < "$src.sql" || die "restore failed; the transaction was rolled back and the database is unchanged"
        echo "  restored domainlist from $f: $(sql 'SELECT COUNT(*) FROM domainlist;') rows"
        reload ;;
esac
