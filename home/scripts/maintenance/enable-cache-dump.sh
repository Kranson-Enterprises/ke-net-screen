#!/bin/bash
# enable-cache-dump.sh — OPERATOR OPT-IN: grant one user passwordless unbound cache
# dumps so collect-appliance-logs.sh can include the DNS cache unattended.
#
# Usage:  sudo ./enable-cache-dump.sh          (interactive; grants or removes)
#
# RISK, read first: the dump (unbound-control dump_cache) exposes the household's
# resolved-name cache — a privacy-sensitive view of what this LAN looks up. By
# design this grant is NEVER applied at image build, deploy, or first boot
# (operator decision 2026-10-31): an operator runs this on the live appliance,
# after deployment, eyes open. A reflash removes the grant; re-run this script.
#
# Mechanism: /etc/sudoers.d/ke-collect-dump holding exactly one rule —
#   <user> ALL=(root) NOPASSWD: /usr/sbin/unbound-control -c /etc/unbound/unbound.conf dump_cache
# validated with visudo -cf BEFORE install (a broken sudoers.d file can take out
# sudo itself), installed 0440 root:root. Nothing else is granted: the command
# line above is the entire attack surface, and it is read-only against unbound.
set -euo pipefail

(( EUID == 0 )) || { echo "enable-cache-dump.sh: needs root (sudo)" >&2; exit 2; }
[[ -t 0 ]] || { echo "enable-cache-dump.sh: interactive; run from a terminal" >&2; exit 2; }

F=/etc/sudoers.d/ke-collect-dump
CMD='/usr/sbin/unbound-control -c /etc/unbound/unbound.conf dump_cache'
TARGET_USER=${SUDO_USER:-}

echo "===== unbound cache-dump grant ====="
if [[ -f $F ]]; then
    echo "  current grant:"
    sed 's/^/    /' "$F"
else
    echo "  no grant installed"
fi
echo
echo "  The dump exposes the household's resolved-name cache (privacy-sensitive)."
echo "  This grant is operator opt-in by design and never applied automatically."
echo
read -rp "  [g]rant to '${TARGET_USER:-unknown}', [r]emove, [q]uit: " ans
case "$ans" in
    g|G)
        if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
            echo "  run via sudo from the operator account (SUDO_USER is empty or root)" >&2
            exit 2
        fi
        id "$TARGET_USER" >/dev/null
        TMP=$(mktemp)
        trap 'rm -f "$TMP"' EXIT
        printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$CMD" > "$TMP"
        visudo -cf "$TMP"
        install -m 0440 -o root -g root "$TMP" "$F"
        echo "  installed $F:"
        sed 's/^/    /' "$F"
        echo "  proof (sudo -l for $TARGET_USER):"
        sudo -n -l -U "$TARGET_USER" 2>/dev/null | grep -F dump_cache | sed 's/^/    /' || true
        ;;
    r|R)
        rm -f "$F"
        echo "  grant removed ($F)"
        ;;
    *)
        echo "  no change"
        ;;
esac
