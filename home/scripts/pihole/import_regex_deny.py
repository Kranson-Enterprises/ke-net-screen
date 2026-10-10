#!/usr/bin/env python3
"""Import regex deny entries into Pi-hole's gravity.db at first boot.

Reads one regex per line from /usr/local/src/pihole/regex_deny.txt (written by the
ke-piholecfg layer from the IGconf_ke_pihole_regex_deny build variable, i.e. the
PIHOLE_REGEX_DENY key in .env) and inserts each as a regex deny entry (domainlist
type 3). Existing entries are left alone, so re-running is safe. The insert trigger
attaches new entries to the default group; the caller reloads FTL's lists.
"""
import os
import sqlite3
import time

DB_PATH = os.environ.get("GRAVITY_DB", "/etc/pihole/gravity.db")
IMPORT_FILE = os.environ.get("REGEX_DENY_FILE", "/usr/local/src/pihole/regex_deny.txt")
REGEX_DENY = 3
COMMENT = "ke-net-screen image default (PIHOLE_REGEX_DENY)"


def import_regex_deny() -> int:
    if not os.path.exists(IMPORT_FILE):
        print(f"No regex deny file at {IMPORT_FILE}; nothing to import.")
        return 0
    patterns = [l.strip() for l in open(IMPORT_FILE, encoding="utf-8") if l.strip() and not l.startswith("#")]
    if not patterns:
        print("Regex deny file is empty; nothing to import.")
        return 0
    if not os.path.exists(DB_PATH):
        print(f"Error: database not found at {DB_PATH}")
        return 1
    added = 0
    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.cursor()
        now = int(time.time())
        for pattern in patterns:
            cur.execute("SELECT id, enabled FROM domainlist WHERE type = ? AND domain = ?", (REGEX_DENY, pattern))
            row = cur.fetchone()
            if row is None:
                cur.execute(
                    "INSERT INTO domainlist (type, domain, enabled, date_added, date_modified, comment) VALUES (?, ?, 1, ?, ?, ?)",
                    (REGEX_DENY, pattern, now, now, COMMENT),
                )
                print(f"✅ Added regex deny: {pattern}")
                added += 1
            else:
                print(f"⚠️ Skipped (already present, enabled={row[1]}): {pattern}")
        conn.commit()
    except sqlite3.Error as e:
        print(f"SQLite error: {e}")
        return 1
    finally:
        conn.close()
    print(f"✅ Regex deny import completed: {added} added, {len(patterns) - added} skipped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(import_regex_deny())
