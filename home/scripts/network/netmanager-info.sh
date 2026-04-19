#!/bin/bash

echo "Network Manager connection details for localmediapi-wired-lan:"
nmcli -p connection show localmediapi-wired-lan

echo "show contents of /boot/firmware/config.txt:"
cat /boot/firmware/config.txt 