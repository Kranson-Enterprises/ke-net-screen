#!/bin/bash
# DNS Health Check Script
# Monitors Pi-hole, Unbound, and Avahi services

set -euo pipefail

LOG_FILE="/var/log/dns-health.log"
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
    
    # Check local mDNS
    if ! command -v avahi-resolve-host-name >/dev/null 2>&1; then
        log_message "✗ avahi-resolve-host-name command not found"
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