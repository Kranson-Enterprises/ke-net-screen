#!/usr/bin/env python3
import sqlite3
import csv
import os
from datetime import datetime

DB_PATH = "/etc/pihole/gravity.db"
EXPORT_FILE = "adlists_export.csv"

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
        """)
        rows = cursor.fetchall()

        with open(EXPORT_FILE, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["id", "address", "enabled", "comment", "date_added", "date_modified"])
            writer.writerows(rows)

        print(f"✅ Export completed: {EXPORT_FILE}")

    except sqlite3.Error as e:
        print(f"SQLite error: {e}")
    finally:
        conn.close()

if __name__ == "__main__":
    export_adlists()
