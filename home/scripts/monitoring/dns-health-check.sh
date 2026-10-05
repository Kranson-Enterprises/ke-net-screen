#!/bin/bash
# DNS Health Check Script
# Monitors Pi-hole, Unbound, and Avahi services

set -euo pipefail

LOG_FILE="/var/log/dns-health.log"
# Self-rotate: cap the local log (journald holds the primary copy via the
# service unit). At the daily cadence 256 KiB is ~100 days per generation;
# one previous generation is kept, bounding total use at ~512 KiB.
LOG_MAX_BYTES=262144
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_message() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
    echo "[$TIMESTAMP] $1"
}

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        log_message "✓ $service is running"
        return 0
    else
        log_message "✗ $service is not running"
        return 1
    fi
}

check_dns_resolution() {
    local test_domain=$1
    local dns_server=$2
    if ! command -v dig >/dev/null 2>&1; then
        log_message "✗ dig command not found; install dnsutils"
        return 1
    fi
    if dig @"$dns_server" "$test_domain" +short >/dev/null 2>&1; then
        log_message "✓ DNS resolution working for $test_domain via $dns_server"
        return 0
    else
        log_message "✗ DNS resolution failed for $test_domain via $dns_server"
        return 1
    fi
}

check_sysctl_min() {
    local key=$1
    local min_value=$2
    local path="/proc/sys/${key//./\/}"

    if [[ ! -r "$path" ]]; then
        log_message "⚠ Unable to read kernel tunable $key at $path"
        return 0
    fi

    local current
    current=$(<"$path")
    if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= min_value )); then
        log_message "✓ $key=$current (>= $min_value)"
        return 0
    fi

    log_message "⚠ $key=$current (expected >= $min_value)"
    return 0
}

check_cpu_governor() {
    # The image boots with cpufreq.default_governor=schedutil (cmdline.txt).
    local expected="schedutil"
    local total=0
    local matching=0

    for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -r "$governor_file" ]] || continue
        total=$((total + 1))
        if grep -q "^${expected}\$" "$governor_file"; then
            matching=$((matching + 1))
        fi
    done

    if [[ $total -eq 0 ]]; then
        log_message "ℹ CPU governor files unavailable on this platform"
        return 0
    fi

    if [[ $matching -eq $total ]]; then
        log_message "✓ CPU governors in $expected mode ($matching/$total)"
    else
        log_message "⚠ CPU governors in $expected mode ($matching/$total)"
    fi
}

check_unbound_cache_stats() {
    if ! command -v unbound-control >/dev/null 2>&1; then
        log_message "ℹ unbound-control not found; skipping cache stats"
        return 0
    fi

    # Unbound emits cumulative counters since start (stats_noreset): total.num.cachemiss
    # is the number of recursions unbound actually performed. A hit *ratio* is not a
    # useful signal here: FTL fronts unbound, answers 60-85% of client queries itself and
    # serves stale for dns.cache.optimizer seconds, so unbound only ever sees names that
    # have already expired in both caches and its ratio sits near 0% by design. Report the
    # recursion rate instead and compare it with FTL's "forwarded" count in the 24h line
    # below (unbound also sees FTL's stale-refresh and retry traffic, so expect it higher).
    local stats hits misses expired prefetch up rate days
    stats=$(unbound-control stats_noreset 2>/dev/null || true)
    hits=$(awk -F= '/^total\.num\.cachehits=/{print $2; exit}' <<< "$stats")
    misses=$(awk -F= '/^total\.num\.cachemiss=/{print $2; exit}' <<< "$stats")
    expired=$(awk -F= '/^total\.num\.expired=/{print $2; exit}' <<< "$stats")
    prefetch=$(awk -F= '/^total\.num\.prefetch=/{print $2; exit}' <<< "$stats")
    up=$(awk -F= '/^time\.up=/{print $2; exit}' <<< "$stats")

    if [[ -n "$hits" && -n "$misses" ]]; then
        days=$(awk "BEGIN {printf \"%.1f\", ${up:-0}/86400}")
        if awk "BEGIN {exit !(${up:-0} >= 3600)}"; then
            rate=$(awk "BEGIN {printf \"%d\", $misses*86400/${up:-1}}")
            log_message "ℹ Unbound: recursions=$misses (~${rate}/day over ${days} days up) prefetch=${prefetch:-0} expired-served=${expired:-0} cache-hits=$hits (FTL fronts the cache; low hits expected)"
        else
            log_message "ℹ Unbound: recursions=$misses (up ${up:-0}s, rate needs >=1h) prefetch=${prefetch:-0} expired-served=${expired:-0} cache-hits=$hits (FTL fronts the cache; low hits expected)"
        fi
    else
        log_message "⚠ Unable to read Unbound cache stats"
    fi
}

check_unbound_provenance() {
    # Source-built unbound is protected from apt overwrite by local dpkg
    # diversions; if the distro binary is parked at *.distrib the diversions
    # must exist, or the next unbound package update clobbers the binary.
    local version diversions
    version=$(/usr/sbin/unbound -V 2>/dev/null | head -1 || true)
    diversions=$(dpkg-divert --list 2>/dev/null | grep -c "local diversion of /usr/sbin/unbound" || true)

    if [[ -e /usr/sbin/unbound.distrib && "$diversions" -eq 0 ]]; then
        log_message "⚠ unbound.distrib exists but no dpkg diversions registered - apt upgrade can clobber the source build"
    else
        log_message "ℹ Unbound: ${version:-unknown} (dpkg diversions: $diversions)"
    fi
}

check_gravity_freshness() {
    # Blocklists should refresh weekly (pihole-gravity.timer). A stale
    # gravity DB previously went unnoticed for 12 days.
    local db="/etc/pihole/gravity.db"
    if [[ ! -f "$db" ]] || ! command -v pihole-FTL >/dev/null 2>&1; then
        log_message "ℹ gravity.db or pihole-FTL not present; skipping freshness check"
        return 0
    fi

    local updated now age_days
    updated=$(pihole-FTL sqlite3 "$db" "SELECT value FROM info WHERE property='updated';" 2>/dev/null || true)
    if [[ ! "$updated" =~ ^[0-9]+$ ]]; then
        log_message "⚠ Unable to read gravity last-update timestamp"
        return 0
    fi
    now=$(date +%s)
    age_days=$(( (now - updated) / 86400 ))
    if (( age_days > 8 )); then
        log_message "⚠ Gravity blocklists are $age_days days old (weekly refresh expected)"
    else
        log_message "✓ Gravity blocklists updated $age_days day(s) ago"
    fi
}

check_ftl_layer_stats() {
    # Client-perceived caching happens at FTL, in front of unbound: report
    # the last 24h split so both layers' ratios appear side by side.
    local db="/etc/pihole/pihole-FTL.db"
    if [[ ! -f "$db" ]] || ! command -v pihole-FTL >/dev/null 2>&1; then
        log_message "ℹ pihole-FTL.db not present; skipping FTL 24h stats"
        return 0
    fi

    local row total cached forwarded ratio
    row=$(pihole-FTL sqlite3 "$db" "SELECT COUNT(*), \
        SUM(CASE WHEN status=3 THEN 1 ELSE 0 END), \
        SUM(CASE WHEN status IN (2,14) THEN 1 ELSE 0 END) \
        FROM queries WHERE timestamp > strftime('%s','now')-86400;" 2>/dev/null || true)
    IFS='|' read -r total cached forwarded <<< "$row"
    if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
        ratio=$(awk "BEGIN {t=${cached:-0}+${forwarded:-0}; printf \"%.1f\", (t ? ${cached:-0}*100/t : 0)}")
        log_message "ℹ FTL 24h: total=$total cached=${cached:-0} forwarded=${forwarded:-0} client-cache-ratio=${ratio}%"
    else
        log_message "ℹ FTL 24h stats unavailable (no queries recorded yet)"
    fi
}

check_ntp_health() {
    # timesyncd owns clock discipline (FTL ntp.sync is off by design);
    # FTL serves NTP to the LAN on port 123.
    local synced
    synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
    if [[ "$synced" == "yes" ]]; then
        log_message "✓ System clock NTP-synchronized (timesyncd)"
    else
        log_message "⚠ System clock not NTP-synchronized (NTPSynchronized=${synced:-unknown})"
    fi

    if ss -ulnH 2>/dev/null | grep -q ":123 "; then
        log_message "✓ NTP listener on port 123 (FTL serving LAN time)"
    else
        log_message "⚠ No NTP listener on port 123 (DHCP option 42 advertises this host)"
    fi
}

check_throttle_state() {
    # 0x0 is healthy; bit 0 = under-voltage now, bit 2 = throttled now,
    # bits 16/18/19 = has occurred since boot.
    if ! command -v vcgencmd >/dev/null 2>&1; then
        return 0
    fi
    local state
    state=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || true)
    if [[ "$state" == "0x0" ]]; then
        log_message "✓ SoC throttle state clean (0x0)"
    elif [[ "$state" =~ ^0x[0-9a-fA-F]+$ ]]; then
        log_message "⚠ SoC throttle state $state (check power supply / cooling)"
    fi
}

check_bootloader_eeprom() {
    # The boot-time rpi-eeprom-update -s -a applies critical minimums only; show the gap to
    # the configured channel's latest so an old bootloader is visible (eeprom-update.sh --apply).
    command -v rpi-eeprom-update >/dev/null 2>&1 || return 0
    local out cur latest chan cur_d latest_d
    out=$(rpi-eeprom-update 2>/dev/null || true)
    cur=$(sed -n 's/.*CURRENT:.*(\([0-9]\+\)).*/\1/p' <<<"$out" | head -1)
    latest=$(sed -n 's/.*LATEST:.*(\([0-9]\+\)).*/\1/p' <<<"$out" | head -1)
    chan=$(sed -n 's/.*RELEASE: \([A-Za-z0-9_-]\+\).*/\1/p' <<<"$out" | head -1)
    if [[ -z "$cur" || -z "$latest" ]]; then
        log_message "ℹ Bootloader EEPROM status unavailable"
        return 0
    fi
    cur_d=$(date -u -d "@$cur" +%F); latest_d=$(date -u -d "@$latest" +%F)
    if (( cur >= latest )); then
        log_message "✓ Bootloader EEPROM $cur_d matches the ${chan:-?} channel"
    else
        log_message "ℹ Bootloader EEPROM $cur_d; channel ${chan:-?} offers $latest_d (stage with: sudo eeprom-update.sh --apply, then reboot)"
    fi
    return 0
}

main() {
    local failures=0

    log_message "Starting DNS health check"

    # Check critical services
    check_service "pihole-FTL" || failures=$((failures + 1))
    check_service "unbound" || failures=$((failures + 1))
    check_service "avahi-daemon" || failures=$((failures + 1))
    check_service "systemd-resolved" || failures=$((failures + 1))

    # Check DNS resolution
    check_dns_resolution "google.com" "127.0.0.1" || failures=$((failures + 1))
    check_dns_resolution "github.com" "127.0.0.1" || failures=$((failures + 1))

    # Performance observability checks (informational)
    check_sysctl_min "net.core.rmem_max" 33554432
    check_sysctl_min "net.core.wmem_max" 33554432
    check_sysctl_min "net.core.netdev_max_backlog" 4096
    check_cpu_governor
    check_unbound_cache_stats
    check_unbound_provenance
    check_gravity_freshness
    check_ftl_layer_stats
    check_ntp_health
    check_throttle_state
    check_bootloader_eeprom

    # Check local mDNS
    if ! command -v avahi-resolve-host-name >/dev/null 2>&1; then
        log_message "✗ avahi-resolve-host-name command not found. Install avahi-utils if desired."
        failures=$((failures + 1))
    elif avahi-resolve-host-name "$(hostname).local" >/dev/null 2>&1; then
        log_message "✓ mDNS resolution working"
    else
        log_message "✗ mDNS resolution failed"
        failures=$((failures + 1))
    fi

    if [[ $failures -eq 0 ]]; then
        log_message "DNS health check completed with no failures"
        return 0
    fi

    log_message "DNS health check completed with $failures failure(s)"
    return 1
}

main "$@"