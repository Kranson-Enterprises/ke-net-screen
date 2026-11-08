#!/bin/bash
# verify-certs.sh — certificate and key-material verification across the appliance's
# TLS/crypto loaders: pihole-FTL (443), the stunnel DoT terminator (853), unbound
# (DNSSEC trust anchor + remote-control cert pair), and avahi (none by design —
# reported honestly rather than faked).
#
# Why: three loaders share or hold long-lived key material with different owners and
# reload behaviors. FTL auto-rotates tls.pem ~2 days BEFORE expiry (a daily runtime
# check; only for certs FTL itself issued — CN pi.hole — and only while
# webserver.tls.validity > 0); stunnel loads it at start as root then DROPS
# PRIVILEGES (setuid stunnel4), so "the served certificate matches the file" is the
# load-order proof for the privilege drop AND the staleness check the cert-watch
# path unit is meant to prevent. Unbound's root.key self-updates via RFC 5011 and
# silently going stale would eventually break all DNSSEC validation.
#
# Usage:
#   sudo ./verify-certs.sh                    # full checks (file parsing needs root)
#   ./verify-certs.sh                         # unprivileged: served-cert probes only
#   sudo ./verify-certs.sh --journal-summary  # body to log; one "certcheck" record
#
# Record: certcheck ts=<ISO> pihole=<ok|WARN|FAIL|skip> stunnel=<...> unbound=<...>
#         avahi=na tls_days=<n> anchor_age_d=<n>
#         ok = all checks pass; WARN = expiring <14 d or anchor stale; FAIL = expired,
#         key/cert mismatch, served!=file, or probe failure; skip = needs root.
#
# Log: /var/log/verify-certs.log, self-rotates at 256 KiB, one previous generation.
#
# CENTRALIZATION MAP (for a future enterprise/CA-issued certificate):
#   /etc/pihole/tls.pem is the host's SINGLE public-facing TLS source — FTL serves it
#   on 443 and the stunnel DoT terminator on 853; the stunnel-cert-watch path unit
#   propagates any change to 853 automatically. To integrate a managed certificate:
#   install the combined key+cert at that path (or repoint webserver.tls.cert in
#   pihole.toml) AND set webserver.tls.validity = 0 so FTL never overwrites a managed
#   cert; renewal must then land before expiry yourself. (FTL regenerates at STARTUP
#   only when the file is MISSING/unreadable — an expired file is left alone at boot;
#   its daily runtime check rotates only FTL-issued certs.) Then run this script —
#   both served-vs-file checks prove the swap took everywhere. Out of scope by design:
#   unbound's control certs (loopback-internal) and its DNSSEC trust anchor, and
#   avahi (no TLS). SSH host keys are a separate domain.
set -euo pipefail

JOURNAL_SUMMARY=0
while (( $# )); do
    case "$1" in
        -j|--journal-summary) JOURNAL_SUMMARY=1 ;;
        -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "verify-certs.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

LOG_FILE="${LOG_FILE:-/var/log/verify-certs.log}"
LOG_MAX_BYTES=262144
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then LOG_FILE=/dev/null; JOURNAL_SUMMARY=0; fi
TS=$(date '+%Y-%m-%d %H:%M:%S')
if (( JOURNAL_SUMMARY )); then body() { cat >> "$LOG_FILE"; }; else body() { tee -a "$LOG_FILE"; }; fi
emit()   { echo "$*" | body; }
record() { echo "$*" | tee -a "$LOG_FILE"; }

ROOT=0; (( EUID == 0 )) && ROOT=1
emit "===== verify-certs $TS (root=$ROOT) ====="

TLS_PEM=/etc/pihole/tls.pem
PIHOLE=skip; STUNNEL=skip; UNBOUND=skip; TLS_DAYS=-; ANCHOR_AGE=-

# served_fp <port> -> sha256 fingerprint of the certificate a local TLS port serves.
# FTL binds 443 on the LAN address (not loopback), so probe the host's primary IP
# first and fall back to loopback (stunnel binds every interface).
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
served_fp() {
    local port=$1 ip
    for ip in ${HOST_IP:-} 127.0.0.1; do
        local fp
        fp=$(echo | timeout 8 openssl s_client -connect "$ip:$port" 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
        [[ -n "$fp" ]] && { echo "$fp"; return 0; }
    done
    return 1
}

# ---- shared tls.pem: parse once (root), probe both consumers -------------------
FILE_FP=""
if (( ROOT )) && [[ -r "$TLS_PEM" ]]; then
    FILE_FP=$(openssl x509 -in "$TLS_PEM" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    END=$(openssl x509 -in "$TLS_PEM" -noout -enddate 2>/dev/null | cut -d= -f2)
    TLS_DAYS=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))
    CERT_PUB=$(openssl x509 -in "$TLS_PEM" -noout -pubkey 2>/dev/null)
    KEY_PUB=$(openssl pkey -in "$TLS_PEM" -pubout 2>/dev/null)
    OWN=$(stat -c '%U:%G %a' "$TLS_PEM")
    emit "--- $TLS_PEM: expires in $TLS_DAYS d ($END); owner $OWN"
    if [[ -z "$CERT_PUB" || "$CERT_PUB" != "$KEY_PUB" ]]; then
        emit "    FAIL: private key does not match the certificate"
        PIHOLE=FAIL; STUNNEL=FAIL
    fi
elif (( ! ROOT )); then
    emit "--- $TLS_PEM: unreadable without root (file checks skipped)"
fi

# pihole-FTL on 443: served cert vs file
FP443=$(served_fp 443 || true)
if [[ -n "$FP443" ]]; then
    if [[ -n "$FILE_FP" ]]; then
        if [[ "$FP443" == "$FILE_FP" ]]; then PIHOLE=ok; emit "--- pihole(443): serving the on-disk cert"
        else PIHOLE=FAIL; emit "--- pihole(443): FAIL — served cert differs from $TLS_PEM"; fi
    else
        PIHOLE=probe-ok; emit "--- pihole(443): TLS answers (file compare needs root)"
    fi
else
    PIHOLE=FAIL; emit "--- pihole(443): FAIL — no TLS handshake"
fi

# stunnel on 853: served cert vs file + runtime uid (the privilege-drop proof)
if systemctl is-active stunnel@dot >/dev/null 2>&1; then
    FP853=$(served_fp 853 || true)
    if [[ -n "$FP853" ]]; then
        if [[ -n "$FILE_FP" ]]; then
            if [[ "$FP853" == "$FILE_FP" ]]; then STUNNEL=ok; emit "--- stunnel(853): serving the on-disk cert (cert loaded before privilege drop — load order OK)"
            else STUNNEL=FAIL; emit "--- stunnel(853): FAIL — served cert differs from $TLS_PEM (stale after rotation, or load failed post-drop)"; fi
        else
            STUNNEL=probe-ok; emit "--- stunnel(853): TLS answers (file compare needs root)"
        fi
        SUSER=$(ps -o user= -C stunnel4 2>/dev/null | sort -u | tr '\n' ' ' || true)
        [[ -n "$SUSER" ]] && emit "    runtime user: $SUSER(want stunnel4 after the drop; root = drop not active)"
    else
        STUNNEL=FAIL; emit "--- stunnel(853): FAIL — unit active but no TLS handshake"
    fi
else
    STUNNEL=na; emit "--- stunnel(853): not active (DOT_TERMINATOR off, or pre-first-boot)"
fi

# ---- unbound: trust anchor + remote-control cert pair --------------------------
ANCHOR=/var/lib/unbound/root.key
if [[ -r "$ANCHOR" ]] || (( ROOT )); then
    if [[ -s "$ANCHOR" ]]; then
        ANCHOR_AGE=$(( ( $(date +%s) - $(stat -c %Y "$ANCHOR") ) / 86400 ))
        STATE=ok
        grep -qE 'DNSKEY|DS' "$ANCHOR" 2>/dev/null || STATE=FAIL
        (( ANCHOR_AGE > 40 )) && STATE=WARN
        UNBOUND=$STATE
        emit "--- unbound anchor: $ANCHOR age ${ANCHOR_AGE} d ($STATE; >40 d = RFC 5011 updates may have stopped)"
    else
        UNBOUND=FAIL; emit "--- unbound anchor: MISSING/empty ($ANCHOR) — DNSSEC validation at risk"
    fi
fi
if (( ROOT )); then
    for pem in /etc/unbound/unbound_server.pem /etc/unbound/unbound_control.pem; do
        if [[ -r "$pem" ]]; then
            CEND=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
            CD=$(( ( $(date -d "${CEND:-now}" +%s) - $(date +%s) ) / 86400 ))
            emit "    control cert $(basename "$pem"): expires in $CD d"
            (( CD < 14 )) && UNBOUND=WARN
        fi
    done
    unbound-control status >/dev/null 2>&1 && emit "    unbound-control over its cert pair: OK" \
        || { emit "    unbound-control: FAILED (control cert/key problem?)"; UNBOUND=FAIL; }
fi
# DNSSEC is the anchor's purpose: one live validation
if command -v dig >/dev/null 2>&1; then
    AD=$(dig +time=4 @127.0.0.1 debian.org +dnssec 2>/dev/null | grep -c 'flags:.* ad' || true)
    BOGUS=$(dig +time=4 @127.0.0.1 dnssec-failed.org 2>/dev/null | grep -c 'SERVFAIL' || true)
    if (( AD >= 1 && BOGUS >= 1 )); then
        emit "--- dnssec live: enforcing (AD on valid, SERVFAIL on bogus)"
        [[ "$UNBOUND" == "skip" ]] && UNBOUND=ok
    else
        emit "--- dnssec live: NOT ENFORCING (AD=$AD bogus-servfail=$BOGUS)"; UNBOUND=FAIL
    fi
fi

# ---- avahi: honest no-op -------------------------------------------------------
emit "--- avahi: no certificate material by design (mDNS); nothing to verify"

# expiry warnings on the shared cert
if [[ "$TLS_DAYS" != "-" ]] && (( TLS_DAYS < 14 )); then
    [[ "$PIHOLE"  == ok ]] && PIHOLE=WARN
    [[ "$STUNNEL" == ok ]] && STUNNEL=WARN
    emit "WARN: tls.pem expires in $TLS_DAYS d — FTL auto-rotates ~2 d before expiry (daily check; FTL-issued certs, validity>0); cert-watch then restarts stunnel. If <2 d and still unrotated: rm the pem + restart pihole-FTL."
fi

record "certcheck ts=$(date '+%Y-%m-%dT%H:%M:%S') pihole=$PIHOLE stunnel=$STUNNEL unbound=$UNBOUND avahi=na tls_days=$TLS_DAYS anchor_age_d=$ANCHOR_AGE"
