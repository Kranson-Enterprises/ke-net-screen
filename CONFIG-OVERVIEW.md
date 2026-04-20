# DNS Infrastructure Configuration Overview

This configuration implements a comprehensive DNS infrastructure for local network management.

## Architecture Components

### DNS Resolution Chain
1. **Client Request** → **Pi-hole (port 53)** → **Unbound (port 5335)** → **Upstream DNS**
2. **Local/mDNS** → **Avahi** → **systemd-resolved** (stub disabled)

### Service Ports
- Pi-hole FTL: 53 (DNS), 80 (Web Interface) 
- Unbound: 5335 (Recursive DNS)
- Avahi: 5353 (mDNS)

### Key Features
- **Ad/Tracker Blocking**: Pi-hole filters malicious domains
- **Privacy**: Unbound provides recursive DNS resolution
- **Local Discovery**: Avahi enables .local domain resolution
- **Performance**: Optimized caching and minimal latency

## Network Configuration

### Static IP Setup
```
Interface: eth0
IP: 192.168.0.53/24
Gateway: 192.168.0.1
DNS: 127.0.0.1 (local), 8.8.8.8, 9.9.9.9 (fallback)
```

### Security Considerations
- SSH restricted to local network only
- SSH allows password authentication but requires public-key authentication method in current policy
- IPv6 disabled (not in use)
- DNS-over-HTTPS/DNS-over-TLS not used; recursive resolution handled by local Unbound
- Rate limiting enabled for Avahi

### DHCP Authority
- DHCP is served by Pi-hole (`etc/pihole/pihole.toml`, `[dhcp] active = true`).
- Router DHCP should be disabled during cutover to avoid lease and resolver conflicts.
- Do not run router DHCP and Pi-hole DHCP at the same time.

## Maintenance Commands

### Service Management
```bash
# Check all DNS services
systemctl status pihole-FTL unbound avahi-daemon systemd-resolved

# Restart DNS stack
systemctl restart systemd-resolved unbound pihole-FTL

# Check DNS resolution
dig @127.0.0.1 google.com

# Check periodic health-check status
systemctl status dns-health-check.timer dns-health-check.service
journalctl -u dns-health-check.service -n 100 --no-pager
```

### Pi-hole Management
```bash
# Update blocklists
pihole -g

# Check query log
pihole tail

# Flush network tables
pihole networkflush
```

### Unbound Management
```bash
# Check configuration
unbound-checkconf

# Monitor statistics
unbound-control stats_noreset

# Flush cache
unbound-control reload
```

### Performance Observability
```bash
# Verify kernel network buffers expected by DNS stack
sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog

# Review Unbound cache behavior
unbound-control stats_noreset | grep -E 'total.cachehits|total.cachemiss'

# Check CPU governor state
grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null
```

## Troubleshooting

### Common Issues
1. **DNS not resolving**: Check service status and port conflicts
2. **Slow resolution**: Verify upstream DNS servers
3. **Local domains not working**: Check Avahi configuration and mDNS setup
4. **Pi-hole not blocking**: Update blocklists and check configuration
5. **Intermittent client connectivity**: Ensure only one DHCP server is active (Pi-hole OR router)

### Log Locations
- Pi-hole: `/var/log/pihole.log`
- Unbound: `/var/log/unbound/unbound.log`
- Avahi: `journalctl -u avahi-daemon`
- systemd-resolved: `journalctl -u systemd-resolved`

## Backup and Recovery

### Backup Targets
- `/etc/pihole/`
- `/etc/unbound/`
- `/etc/avahi/`
- `/etc/systemd/resolved.conf.d/`
- `/etc/systemd/network/`

### Manual Backup Command
```bash
sudo tar -czf /var/backups/ke-net-screen-config-$(date +%F).tgz \
	/etc/pihole /etc/unbound /etc/avahi /etc/systemd/resolved.conf.d /etc/systemd/network
```

### Restore Command
```bash
sudo tar -xzf /var/backups/ke-net-screen-config-YYYY-MM-DD.tgz -C /
sudo systemctl restart systemd-resolved unbound pihole-FTL avahi-daemon
```

## Incident Response Quick Steps

1. Confirm DNS stack process state:
```bash
sudo systemctl status pihole-FTL unbound avahi-daemon systemd-resolved
```

2. Inspect health-check service output:
```bash
sudo journalctl -u dns-health-check.service -n 200 --no-pager
```

3. Validate resolver behavior:
```bash
dig @127.0.0.1 github.com
dig @127.0.0.1 pi-hole.net
```

4. If needed, restart the stack:
```bash
sudo systemctl restart systemd-resolved unbound pihole-FTL avahi-daemon
```