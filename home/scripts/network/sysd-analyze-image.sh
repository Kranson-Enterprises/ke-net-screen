#!/bin/bash

systemd-analyze dump > ~/SystemdAnalyzeDump.txt
vi ~/SystemdAnalyzeDump.txt
systemd-analyze plot > ~/SystemdAnalyzePlot.svg
eog ~/SystemdAnalyzePlot.svg
# sudo apt install eog
eog ~/SystemdAnalyzePlot.svg
echo "Systemd analyze dump saved to SystemdAnalyzeDump.txt"
echo "Systemd analyze plot saved to SystemdAnalyzePlot.svg"