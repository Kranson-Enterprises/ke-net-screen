#!/usr/bin/env python3
"""Import Pi-hole adlists from CSV (needs columns address, enabled, comment).

Default input is /usr/local/src/pihole/adlists_export.csv (first-boot install), as before.
An optional first argument (or IMPORT_FILE) names another file; GRAVITY_DB overrides the
database. Existing addresses are skipped, so re-running is safe. import-adlist.sh wraps this
for backups in ~/pihole-adlist-backups.
"""
import sqlite3
import csv
import os
import sys
import time

DB_PATH = os.environ.get("GRAVITY_DB", "/etc/pihole/gravity.db")
IMPORT_FILE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("IMPORT_FILE", "/usr/local/src/pihole/adlists_export.csv")

def import_adlists():
    if not os.path.exists(DB_PATH):
        print(f"Error: Database not found at {DB_PATH}")
        return
    if not os.path.exists(IMPORT_FILE):
        print(f"Error: Import file not found: {IMPORT_FILE}")
        return

    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        with open(IMPORT_FILE, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                address = row["address"].strip()
                enabled = int(row["enabled"]) if (row.get("enabled") or "").isdigit() else 1
                comment = (row.get("comment") or "").strip()
                now = int(time.time())

                # Avoid duplicates
                cursor.execute("SELECT COUNT(*) FROM adlist WHERE address = ?", (address,))
                if cursor.fetchone()[0] == 0:
                    cursor.execute("""
                        INSERT INTO adlist (address, enabled, comment, date_added, date_modified)
                        VALUES (?, ?, ?, ?, ?)
                    """, (address, enabled, comment, now, now))
                    print(f"✅ Added: {address}")
                else:
                    print(f"⚠️ Skipped (already exists): {address}")

        conn.commit()
        print("✅ Import completed successfully.")

    except sqlite3.Error as e:
        print(f"SQLite error: {e}")
    finally:
        conn.close()

if __name__ == "__main__":
    import_adlists()
