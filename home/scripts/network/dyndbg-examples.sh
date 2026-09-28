#!/bin/bash
# dyndbg-examples.sh — reference + helper for kernel DYNAMIC DEBUG.
#
# WHY: to chase ONE subsystem in depth you enable its pr_debug() messages instead of
# raising the whole console log level. This keeps the resolver's serial console quiet
# (important on this appliance: console=ttyAMA10,115200 — flooding it adds DNS latency)
# while still capturing detail in the kernel ring buffer.
#
# REQUIREMENTS:
#   * kernel built with CONFIG_DYNAMIC_DEBUG=y (most distro/Pi kernels are)
#   * debugfs mounted:   sudo mount -t debugfs none /sys/kernel/debug   (usually already)
#   * control file:      /sys/kernel/debug/dynamic_debug/control
#
# READ THE OUTPUT (no console change needed — the ring buffer captures it):
#   sudo dmesg -w                 # live
#   sudo journalctl -k -f         # live via journald
#   sudo journalctl -k --since "10 min ago"
#
# CONTROL SYNTAX (write query + flags to the control file):
#   echo 'module <mod>  +p'  | sudo tee /sys/kernel/debug/dynamic_debug/control   # enable
#   echo 'module <mod>  -p'  | sudo tee /sys/kernel/debug/dynamic_debug/control   # disable
#   selectors: module <m> | func <fn> | file <path> | line <n|a-b> | format '<substr>'
#   flags:  p=print message  f=+function  l=+line  m=+module  t=+thread-id
#   Narrow with func/file/format to avoid a firehose; enable, observe, DISABLE promptly.
#
# ------------------------------------------------------------------------------------
# EXAMPLES — NETWORKING
# ------------------------------------------------------------------------------------
#   # netfilter / connection tracking (dropped or invalid packets, NAT decisions):
#   echo 'module nf_conntrack +p'      | sudo tee /sys/kernel/debug/dynamic_debug/control
#   echo 'module nf_conntrack_proto_tcp +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
#
#   # TCP stack — VERY chatty; scope to a function or format string, not the whole module:
#   echo 'func tcp_retransmit_skb +p'  | sudo tee /sys/kernel/debug/dynamic_debug/control
#   echo 'format "retransmit" +p'      | sudo tee /sys/kernel/debug/dynamic_debug/control
#
#   # Pi 5 wired NIC driver (link flaps, ring/queue issues):
#   echo 'module bcmgenet +p'          | sudo tee /sys/kernel/debug/dynamic_debug/control
#   # (older Pi / USB NICs: module smsc95xx  or  module lan78xx)
#
#   # Wi-Fi stack (only if you are auditing why wlan0 exists on the "wireless-disabled" build):
#   echo 'module cfg80211 +p'          | sudo tee /sys/kernel/debug/dynamic_debug/control
#   echo 'module brcmfmac +p'          | sudo tee /sys/kernel/debug/dynamic_debug/control
#
#   # Bridging / VLAN (relevant if you ever segment on-box):
#   echo 'module br_netfilter +p'      | sudo tee /sys/kernel/debug/dynamic_debug/control
#   echo 'module 8021q +p'             | sudo tee /sys/kernel/debug/dynamic_debug/control
#
# ------------------------------------------------------------------------------------
# EXAMPLES — SECURITY
# ------------------------------------------------------------------------------------
#   # AppArmor (LSM allow/deny decisions):
#   echo 'module apparmor +p'          | sudo tee /sys/kernel/debug/dynamic_debug/control
#   # IMA / integrity measurement:
#   echo 'module ima +p'               | sudo tee /sys/kernel/debug/dynamic_debug/control
#   # Kernel keyring / crypto:
#   echo 'module keyring +p'           | sudo tee /sys/kernel/debug/dynamic_debug/control
#   # (Note: the kernel AUDIT subsystem is DISABLED on this image's cmdline — audit rules
#   #  won't fire here; dynamic_debug is your in-kernel visibility instead.)
#
# ------------------------------------------------------------------------------------
# EXAMPLES — OTHER SUBSYSTEMS
# ------------------------------------------------------------------------------------
#   echo 'module nvme +p'   | sudo tee /sys/kernel/debug/dynamic_debug/control   # NVMe SSD
#   echo 'module mmc_core +p' | sudo tee /sys/kernel/debug/dynamic_debug/control # SD/eMMC
#   echo 'module usbcore +p' | sudo tee /sys/kernel/debug/dynamic_debug/control  # USB
#   echo 'file drivers/thermal/* +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
#
# ------------------------------------------------------------------------------------
# TURN IT BACK OFF (always do this when done — some modules flood):
#   echo 'module <mod> -p' | sudo tee /sys/kernel/debug/dynamic_debug/control
#   # Disable EVERYTHING currently enabled:
#   sudo awk -F'[: ]' '/=p/{print "file "$1" -p"}' /sys/kernel/debug/dynamic_debug/control \
#     | sudo tee /sys/kernel/debug/dynamic_debug/control >/dev/null
# ------------------------------------------------------------------------------------

set -euo pipefail
CTL=/sys/kernel/debug/dynamic_debug/control

preflight() {
  if [[ ! -e "$CTL" ]]; then
    echo "dynamic_debug control not found at $CTL"
    echo "  try: sudo mount -t debugfs none /sys/kernel/debug"
    echo "  and verify the kernel has CONFIG_DYNAMIC_DEBUG=y"
    return 1
  fi
}

usage() {
  cat <<USAGE
dyndbg-examples.sh — read the comments in this file for copy-paste examples.

Helpers (all require sudo to write the control file):
  $0 list                 # show currently-ENABLED debug points (flags =p)
  $0 grep <keyword>       # search available debug points (e.g. conntrack, tcp, nvme)
  $0 enable 'module nf_conntrack'   # enable a selector (+p)
  $0 disable 'module nf_conntrack'  # disable a selector (-p)
  $0 disable-all          # turn off every enabled debug point

Then watch:  sudo journalctl -k -f     (or: sudo dmesg -w)
Reminder: enable narrowly, observe, then disable — and do NOT raise kernel.printk on
the appliance (serial console latency). See private/kernel-debug-network-gathering-plan.md.
USAGE
}

cmd="${1:-help}"
case "$cmd" in
  list)       preflight && grep -E '=p( |$)|=p[a-z]' "$CTL" || echo "(none enabled)";;
  grep)       preflight && grep -i "${2:?keyword}" "$CTL" | head -40;;
  enable)     preflight && echo "${2:?selector} +p" | sudo tee "$CTL" >/dev/null && echo "enabled: $2";;
  disable)    preflight && echo "${2:?selector} -p" | sudo tee "$CTL" >/dev/null && echo "disabled: $2";;
  disable-all)preflight && awk -F'[: ]' '/=p/{print "file "$1" -p"}' "$CTL" | sudo tee "$CTL" >/dev/null && echo "all disabled";;
  *)          usage;;
esac
