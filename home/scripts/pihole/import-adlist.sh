#!/bin/bash
# import-adlist.sh — import Pi-hole adlists from an export in ~/pihole-adlist-backups (or any
# CSV in that format) without touching lists that already exist, then optionally run gravity.
# The first-boot install uses the same importer with the image's CSV; this is the hand-run twin.
#
# Usage:
#   ./import-adlist.sh [FILE]             # dry run: show which adlists FILE (default: latest backup) would add
#   sudo ./import-adlist.sh FILE --apply  # import missing adlists, reload FTL lists
#   sudo ./import-adlist.sh FILE --apply --gravity   # ... and run pihole -g so the new lists are downloaded
#   ./import-adlist.sh --help
#
# Behaviour: existing addresses are skipped (never duplicated or modified); new lists are added
#   with their enabled flag and comment from the CSV. A backup export is taken first with
#   export-adlist.sh so the previous state stays in ~/pihole-adlist-backups.
# Exit: 0 ok, 2 usage, 3 error.

set -euo pipefail

FILE=""; APPLY=0; GRAVITY=0
while (( $# )); do
    case "$1" in
        --apply)   APPLY=1 ;;
        --gravity) GRAVITY=1 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "import-adlist.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
        *) [[ -z "$FILE" ]] || { echo "import-adlist.sh: one file only" >&2; exit 2; }; FILE=$1 ;;
    esac
    shift
done

GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
IMPORTER="${IMPORTER:-/usr/local/src/pihole/import_adlists.py}"
EXPORT_HELPER="${EXPORT_HELPER:-$(dirname "$0")/export-adlist.sh}"
HOME_DIR=$HOME; if [[ -n "${SUDO_USER:-}" ]]; then HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
BACKUP_DIR="${BACKUP_DIR:-$HOME_DIR/pihole-adlist-backups}"
RELOAD_CMD="${RELOAD_CMD:-pihole reloadlists}"
GRAVITY_CMD="${GRAVITY_CMD:-pihole -g}"
die() { echo "import-adlist.sh: $*" >&2; exit 3; }

if [[ -z "$FILE" ]]; then FILE=$(ls -1t "$BACKUP_DIR"/adlists-*.csv 2>/dev/null | head -1 || true); fi
[[ -n "$FILE" && -r "$FILE" ]] || die "no CSV given and no export in $BACKUP_DIR"
[[ -r "$GRAVITY_DB" ]] || die "cannot read $GRAVITY_DB (run with sudo)"
head -1 "$FILE" | grep -q 'address' || die "$FILE has no 'address' column"

# What would change: addresses in the file that the database does not have.
existing=$(sqlite_cmd=$(command -v pihole-FTL >/dev/null 2>&1 && echo "pihole-FTL sqlite3" || echo sqlite3); $sqlite_cmd "$GRAVITY_DB" "SELECT address FROM adlist;" | sort)
wanted=$(python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")): print(r["address"].strip())' "$FILE" | sort -u)
new=$(comm -13 <(printf '%s\n' "$existing") <(printf '%s\n' "$wanted"))
echo "===== import-adlist: $FILE"
echo "  in file: $(printf '%s\n' "$wanted" | grep -c .)   already present: $(comm -12 <(printf '%s\n' "$existing") <(printf '%s\n' "$wanted") | grep -c . || true)   would add: $(printf '%s\n' "$new" | grep -c . || true)"
[[ -n "$new" ]] && printf '  + %s\n' $new

if (( ! APPLY )); then echo "  dry run; add --apply to import (sudo), --gravity to download the new lists afterwards"; exit 0; fi
[[ -n "$new" ]] || { echo "  nothing to import"; exit 0; }
(( EUID == 0 )) || [[ -w "$GRAVITY_DB" ]] || die "--apply needs root (sudo)"
[[ -f "$IMPORTER" ]] || die "importer missing: $IMPORTER"
if [[ -x "$EXPORT_HELPER" ]]; then GRAVITY_DB="$GRAVITY_DB" BACKUP_DIR="$BACKUP_DIR" "$EXPORT_HELPER" --no-diff | sed 's/^/  pre-import /'; fi
GRAVITY_DB="$GRAVITY_DB" python3 "$IMPORTER" "$FILE"
echo "  reloading FTL lists: $RELOAD_CMD"; $RELOAD_CMD >/dev/null 2>&1 || echo "  !! reload failed; run '$RELOAD_CMD' by hand" >&2
if (( GRAVITY )); then echo "  running gravity: $GRAVITY_CMD"; $GRAVITY_CMD || echo "  !! gravity failed; run '$GRAVITY_CMD' by hand" >&2
else echo "  new lists are registered; run 'pihole -g' (or --gravity) to download them"; fi
