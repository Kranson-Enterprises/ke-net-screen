#!/bin/bash
# Reference utility for Pi-hole adlist management (export/import)
# Note: This is a utility fragment and not integrated into the main build process.
# Use these commands as a reference for manual adlist backup/restore operations.

# Export
sudo python3 export_adlists.py

sudo cp /etc/pihole/gravity.db /etc/pihole/gravity.db.bak
# Import
sudo python3 import_adlists.py
# Update Gravity
# pihole -g

sudo pihole restartdns reload-lists
