#!/bin/bash
# export-adlist.sh — export Pi-hole's adlists to a timestamped CSV in ~/pihole-adlist-backups
# and show what changed since the previous export. Keep these to compare list sets between
# updates, or to rebuild the lists if the appliance (or access to it) is ever lost.
#
# Usage:
#   sudo ./export-adlist.sh               # export to ~/pihole-adlist-backups/adlists-<stamp>-<pid>.csv, diff vs previous
#   sudo ./export-adlist.sh --no-diff     # export only
#   ./export-adlist.sh --diff [A] [B]     # compare two exports (default: the two most recent); no export
#   ./export-adlist.sh --list             # list backups with their counts
#   sudo ./export-adlist.sh --domains     # the realized block list: every domain gravity imported from
#                                         # the adlists, one per line, to gravity-domains-<stamp>-<pid>.txt
#   ./export-adlist.sh --domains-diff [A] [B]   # added/removed domains between two domain exports (default: two most recent)
#   ./export-adlist.sh --help
#
# Files: CSV with id,address,enabled,comment,date_added,date_modified — the same format the
#   image's first-boot import uses (home/scripts/pihole/adlists_export.csv), so a backup can be
#   dropped into private/ for the next build or fed to import-adlist.sh. --domains writes the
#   gravity table itself (what the lists resolved to at the last `pihole -g`): sorted, unique,
#   one domain per line, ~1 M lines / ~30 MB for the household set; the summary on stdout gives
#   per-list counts and the effective count (enabled lists and groups only, vw_gravity).
# Access: reading /etc/pihole/gravity.db needs sudo on the appliance (owned by pihole); the
#   backups are written to the invoking user's home (SUDO_USER aware), mode 0600.
# Exit: 0 ok, 1 differences shown by --diff, 2 usage, 3 error.

set -euo pipefail

MODE=export; DO_DIFF=1; A=""; B=""
while (( $# )); do
    case "$1" in
        --no-diff) DO_DIFF=0 ;;
        --diff)    MODE=diff; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { A=$2; shift; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { B=$2; shift; }; } ;;
        --list)    MODE=list ;;
        --domains) MODE=domains ;;
        --domains-diff) MODE=ddiff; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { A=$2; shift; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { B=$2; shift; }; } ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "export-adlist.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
EXPORTER="${EXPORTER:-/usr/local/src/pihole/export_adlists.py}"
if [[ -z "${SQLITE_CMD:-}" ]]; then
    if command -v pihole-FTL >/dev/null 2>&1; then SQLITE_CMD="pihole-FTL sqlite3"; else SQLITE_CMD="sqlite3"; fi
fi
sql() { $SQLITE_CMD "$GRAVITY_DB" "$@"; }
HOME_DIR=$HOME; if [[ -n "${SUDO_USER:-}" ]]; then HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
BACKUP_DIR="${BACKUP_DIR:-$HOME_DIR/pihole-adlist-backups}"
die() { echo "export-adlist.sh: $*" >&2; exit 3; }
count() { local n; n=$(($(wc -l < "$1") - 1)); (( n < 0 )) && n=0; echo "$n"; }
# address|enabled per line, sorted, for diffing (ids and dates differ between databases)
keyed() { python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")): print(r["address"].strip() + "|" + ((r.get("enabled") or "1").strip()))' "$1" | sort; }

diff_exports() {
    local a=$1 b=$2
    echo "===== adlist diff: $(basename "$a") -> $(basename "$b")"
    local removed added toggled
    removed=$(comm -23 <(keyed "$a" | cut -d'|' -f1) <(keyed "$b" | cut -d'|' -f1))
    added=$(comm -13 <(keyed "$a" | cut -d'|' -f1) <(keyed "$b" | cut -d'|' -f1))
    toggled=$(comm -3 <(keyed "$a") <(keyed "$b") | sed 's/^\t//' | cut -d'|' -f1 | sort | uniq -d)
    [[ -n "$removed" ]] && printf '  - removed: %s\n' $removed
    [[ -n "$added"   ]] && printf '  + added:   %s\n' $added
    [[ -n "$toggled" ]] && printf '  ~ enabled flag changed: %s\n' $toggled
    if [[ -z "$removed$added$toggled" ]]; then echo "  no differences ($(count "$b") adlists)"; return 0; fi
    return 1
}

domains_diff() {   # both files sorted unique, one domain per line
    local a=$1 b=$2 removed added
    removed=$(comm -23 "$a" "$b"); added=$(comm -13 "$a" "$b")
    local nr na; nr=$(printf '%s' "$removed" | grep -c . || true); na=$(printf '%s' "$added" | grep -c . || true)
    echo "===== gravity domains diff: $(basename "$a") ($(grep -c . "$a")) -> $(basename "$b") ($(grep -c . "$b")): -$nr +$na"
    (( nr )) && { echo "  - removed (first 10):"; printf '%s\n' "$removed" | head -10 | sed 's/^/      /'; }
    (( na )) && { echo "  + added (first 10):";   printf '%s\n' "$added"   | head -10 | sed 's/^/      /'; }
    (( nr + na == 0 )) && { echo "  no differences"; return 0; }
    return 1
}

case "$MODE" in
    list)
        # globs via nullglob: a missing kind must not abort the listing under set -e/pipefail
        shopt -s nullglob
        csvs=("$BACKUP_DIR"/adlists-*.csv); doms=("$BACKUP_DIR"/gravity-domains-*.txt)
        shopt -u nullglob
        for f in "${csvs[@]}"; do printf '  %s  %3d adlists\n' "$(basename "$f")" "$(count "$f")"; done
        for f in "${doms[@]}"; do printf '  %s  %d domains\n' "$(basename "$f")" "$(grep -c . "$f" || true)"; done
        (( ${#csvs[@]} + ${#doms[@]} )) || echo "no exports in $BACKUP_DIR" ;;
    domains)
        [[ -r "$GRAVITY_DB" ]] || die "cannot read $GRAVITY_DB (run with sudo)"
        command -v ${SQLITE_CMD%% *} >/dev/null 2>&1 || die "no sqlite shell (${SQLITE_CMD%% *})"
        install -d -m 0700 "$BACKUP_DIR"
        out="$BACKUP_DIR/gravity-domains-$(date +%Y%m%d-%H%M%S)-$$.txt"
        while [[ -e "$out" ]]; do out="${out%.txt}x.txt"; done
        sql "SELECT DISTINCT domain FROM gravity ORDER BY domain;" > "$out"
        chmod 0600 "$out"
        if [[ -n "${SUDO_USER:-}" ]]; then chown "$SUDO_USER" "$BACKUP_DIR" "$out" 2>/dev/null || true; fi
        echo "===== gravity domains export: $out"
        echo "  unique domains: $(grep -c . "$out")   effective (enabled lists/groups): $(sql 'SELECT COUNT(DISTINCT domain) FROM vw_gravity;')   last gravity run: $(sql "SELECT datetime(value,'unixepoch') FROM info WHERE property='updated';" 2>/dev/null || echo unknown)"
        echo "  per list:"
        sql "SELECT printf('    %8d  %s%s', COUNT(*), a.address, CASE a.enabled WHEN 1 THEN '' ELSE '  (disabled)' END) FROM gravity g JOIN adlist a ON a.id = g.adlist_id GROUP BY g.adlist_id ORDER BY COUNT(*) DESC;"
        prev=$(ls -1t "$BACKUP_DIR"/gravity-domains-*.txt 2>/dev/null | sed -n '2p' || true)
        if (( DO_DIFF )) && [[ -n "$prev" ]]; then domains_diff "$prev" "$out" || true; fi ;;
    ddiff)
        if [[ -z "$A" ]]; then mapfile -t two < <(ls -1t "$BACKUP_DIR"/gravity-domains-*.txt 2>/dev/null | head -2); (( ${#two[@]} == 2 )) || die "need two domain exports in $BACKUP_DIR (or give two files)"; B=${two[0]}; A=${two[1]}; fi
        [[ -n "$B" && -r "$A" && -r "$B" ]] || die "--domains-diff needs two readable files, or none for the two most recent"
        domains_diff "$A" "$B" ;;
    diff)
        if [[ -z "$A" ]]; then mapfile -t two < <(ls -1t "$BACKUP_DIR"/adlists-*.csv 2>/dev/null | head -2); (( ${#two[@]} == 2 )) || die "need two exports in $BACKUP_DIR (or give two files)"; B=${two[0]}; A=${two[1]}; fi
        [[ -n "$B" ]] || die "--diff needs two files, or none for the two most recent"
        [[ -r "$A" && -r "$B" ]] || die "cannot read $A or $B"
        diff_exports "$A" "$B" ;;
    export)
        [[ -r "$GRAVITY_DB" ]] || die "cannot read $GRAVITY_DB (run with sudo)"
        [[ -f "$EXPORTER" ]] || die "exporter missing: $EXPORTER"
        install -d -m 0700 "$BACKUP_DIR"
        prev=$(ls -1t "$BACKUP_DIR"/adlists-*.csv 2>/dev/null | head -1 || true)
        out="$BACKUP_DIR/adlists-$(date +%Y%m%d-%H%M%S)-$$.csv"
        while [[ -e "$out" ]]; do out="${out%.csv}x.csv"; done
        GRAVITY_DB="$GRAVITY_DB" python3 "$EXPORTER" "$out"
        chmod 0600 "$out"
        if [[ -n "${SUDO_USER:-}" ]]; then chown "$SUDO_USER" "$BACKUP_DIR" "$out" 2>/dev/null || true; fi
        echo "  exported $(count "$out") adlists to $out"
        if (( DO_DIFF )) && [[ -n "$prev" ]]; then diff_exports "$prev" "$out" || true; fi ;;
esac
