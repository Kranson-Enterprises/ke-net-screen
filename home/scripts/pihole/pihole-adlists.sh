# Export
sudo python3 export_adlists.py

sudo cp /etc/pihole/gravity.db /etc/pihole/gravity.db.bak
# Import
sudo python3 import_adlists.py
# Update Gravity
# pihole -g

sudo pihole restartdns reload-lists
