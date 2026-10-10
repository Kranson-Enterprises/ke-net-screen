#!/usr/bin/env python3
"""Export Pi-hole adlists to CSV (id, address, enabled, comment, date_added, date_modified).

Default output is adlists_export.csv in the current directory, as before. An optional
first argument (or EXPORT_FILE) names another file; GRAVITY_DB overrides the database.
export-adlist.sh wraps this for timestamped backups in ~/pihole-adlist-backups.
"""
import sqlite3
import csv
import os
import sys

DB_PATH = os.environ.get("GRAVITY_DB", "/etc/pihole/gravity.db")
EXPORT_FILE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("EXPORT_FILE", "adlists_export.csv")

def export_adlists():
    if not os.path.exists(DB_PATH):
        print(f"Error: Database not found at {DB_PATH}")
        return

    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        cursor.execute("""
            SELECT id, address, enabled, comment,
                   datetime(date_added, 'unixepoch') AS date_added,
                   datetime(date_modified, 'unixepoch') AS date_modified
            FROM adlist
            ORDER BY id
        """)
        rows = cursor.fetchall()

        with open(EXPORT_FILE, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["id", "address", "enabled", "comment", "date_added", "date_modified"])
            writer.writerows(rows)

        print(f"✅ Export completed: {EXPORT_FILE} ({len(rows)} adlists)")

    except sqlite3.Error as e:
        print(f"SQLite error: {e}")
    finally:
        conn.close()

if __name__ == "__main__":
    export_adlists()
