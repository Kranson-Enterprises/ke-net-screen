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
    if dig @"$dns_server" "$test_domain" +short >/dev/null 2>&1; then
        log_message "✓ DNS resolution working for $test_domain via $dns_server"
        return 0
    else
        log_message "✗ DNS resolution failed for $test_domain via $dns_server"
        return 1
    fi
}

main() {
    log_message "Starting DNS health check"
    
    # Check critical services
    check_service "pihole-FTL"
    check_service "unbound"
    check_service "avahi-daemon"
    check_service "systemd-resolved"
    
    # Check DNS resolution
    check_dns_resolution "google.com" "127.0.0.1"
    check_dns_resolution "github.com" "127.0.0.1"
    
    # Check local mDNS
    if avahi-resolve-host-name "$(hostname).local" >/dev/null 2>&1; then
        log_message "✓ mDNS resolution working"
    else
        log_message "✗ mDNS resolution failed"
    fi
    
    log_message "DNS health check completed"
}

main "$@"