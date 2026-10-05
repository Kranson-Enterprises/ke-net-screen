# DNS Infrastructure Configuration Overview

This configuration implements a comprehensive DNS infrastructure for local network management.

## Architecture Components

### DNS Resolution Chain

1. **Client Request** → **Pi-hole (port 53)** → **Unbound (port 5335)** → **Upstream DNS**
2. **Local/mDNS** → **Avahi** → **systemd-resolved** (stub disabled)
3. **LAN time** → **FTL NTP (port 123)**, advertised to clients via DHCP option 42
4. **Appliance clock** ← **systemd-timesyncd** ← Debian NTP pool

### Service Ports

- Pi-hole FTL: 53 (DNS), 80 (Web Interface), 67/udp (DHCP), 123/udp (NTP LAN time service)
- Unbound: 5335 (Recursive DNS)
- Avahi: 5353 (mDNS)
- SSH: 22 (bound to the static LAN IP only)

### Key Features

- **Ad/Tracker Blocking**: Pi-hole filters malicious domains
- **Privacy**: Unbound provides recursive DNS resolution
- **Performance**: Optimized caching and minimal latency
- **Outage Resilience**: serve-expired keeps answers flowing from stale cache when the WAN is down
- **Local Discovery**: Avahi enables .local domain resolution
- **Wired-only Slimming**: Wi-Fi/Bluetooth disabled in firmware, wireless modules blacklisted, iwd removed

## Network Configuration

### Static IP Setup

```text
Interface: eth0
IP: 192.168.0.53/24
Gateway: 192.168.0.1
DNS: 127.0.0.1 (local), 8.8.8.8, 9.9.9.9 (fallback)
```

### Time Service (NTP)

- FTL serves NTP to the LAN (`ntp.ipv4`/`ntp.ipv6` active on port 123).
- `ntp.sync.active = false`: FTL never steers the system clock — systemd-timesyncd
  solely disciplines it (two NTP clients steering one clock oscillate).
- FTL advertises the appliance as the LAN time server via DHCP option 42
  automatically — native behavior whenever its NTP server and DHCP are both
  active (no manual `dnsmasq_lines` entry; one would be ignored as a
  duplicate). Caveat: Windows ignores option 42 by default; DHCP-respecting
  clients (Linux, Apple, IoT) pick it up as their leases renew.
- timesyncd drop-in `SaveIntervalSec=600` reduces clock-file writes ~10× (wear
  cadence; the Pi 5's real RTC covers boot-time plausibility).
- Known trade-off (accepted): with `ntp.sync` off, FTL serves time at
  stratum 0 — SNTP/IoT clients accept it, but strict NTP clients (chrony,
  ntpd) reject stratum 0 and fall back to their configured servers.

### Security Considerations

- SSH restricted to local network only (ListenAddress bound to the static LAN IP)
- SSH accepts both password and public-key authentication; key-only mode (`AuthenticationMethods publickey`) is present but commented in the policy pending debugging of remote-login issues — see "SSH Debugging Quick Reference" below
- Unbound is source-built (1.26.x, hardened compile flags) and protected by local dpkg diversions so package upgrades cannot overwrite it
- TCP Fast Open server support compiled into Unbound (opt-in `UNBOUND_ENABLE_TFO_SERVER` in `.env`); with `net.ipv4.tcp_fastopen = 3` the DNS-over-TCP fallback path accepts query-in-SYN — verified end-to-end via the kernel's `TCPFastOpenPassive` counter
- Kernel module blacklist (`/etc/modprobe.d/ke-appliance-blacklist.conf`): Wi-Fi, camera, and unused buses disabled; display stack, fan control, power button, and under-voltage monitoring deliberately kept
- IPv6 disabled (not in use)
- DNS-over-HTTPS/DNS-over-TLS not used; recursive resolution handled by local Unbound
- DNSSEC: Unbound validates (bogus answers SERVFAIL); FTL forwards the validated AD bit to clients via `proxy-dnssec` (safe: the only upstream is our own validating Unbound on loopback)
- Rate limiting enabled for Avahi

### DHCP Authority

- DHCP is served by Pi-hole (`etc/pihole/pihole.toml`, `[dhcp] active = true`).
- Lease time is 2 days (renewals begin at ~24 h).
- DHCP option 42 advertises this appliance's NTP service to clients.
- Router DHCP should be disabled during cutover to avoid lease and resolver conflicts.
- Do not run router DHCP and Pi-hole DHCP at the same time.

## Caching and Timing Architecture

Two cache layers sit in front of the internet, each with a distinct job:

- **FTL (client-facing)**: 10,000-entry cache with `optimizer = 3600` —
  answers expired-by-≤1h entries *instantly* while revalidating in the
  background (latency stale-serving).
- **Unbound (resolver)**: 16 MB msg/rrset caches (single-slab, matching
  `num-threads: 1`), `prefetch` + `prefetch-key`, and `serve-expired` with a
  1800 ms client-timeout — if recursion exceeds 1.8 s (slow or dead WAN),
  answer from stale cache instead; `serve-expired-ttl-reset` keeps answers
  flowing through outages longer than a day (resilience stale-serving).

### TTL Ladder

| Rung | Setting | Value |
| --- | --- | --- |
| TTL floor | unbound `cache-min-ttl` | 60 s |
| Blocked-answer TTL | FTL `blockTTL` | 180 s |
| Instant-stale window | FTL `optimizer` | 3600 s |
| TTL cap / stale reservoir | `cache-max-ttl` / `serve-expired-ttl` | 86400 s |

Each rung divides the next cleanly (60 → 180 → 3600 → 86400), so refresh
events align rather than beat against each other.

### Timeout Nesting

`376 ms` upstream probe budget < `1800 ms` stale fallback < `~5 s` client
stub retry < `~10 s` FTL forward-slot expiry — every inner layer resolves or
falls back before the outer layer retries, so a slow upstream produces one
answer path, not competing ones.

TCP reuse rung: unbound holds idle client TCP connections for `120 s`
(`tcp-idle-timeout`, raised from 30 s) so FTL's keepalive-unaware socket
reuse rarely races an idle close ("Connection prematurely closed" log
noise; FTL retries transparently either way).

### Cache Metrics: Why Unbound Reports Recursions, Not a Hit Ratio

The Unbound-layer hit ratio is structurally near zero (observed 0.4 % over
three weeks) and says nothing about health: FTL fronts Unbound, answers
60–85 % of client queries from its own cache and serves stale answers for
`dns.cache.optimizer` seconds while refreshing, so Unbound only ever sees
names that have already expired in both caches. The health check therefore
reports Unbound's *recursion rate* (cache misses per day since start) next to
FTL's 24 h cached/forwarded split. The number that reflects user experience
is FTL's cached/(cached+forwarded) ratio; Unbound's recursions/day should
sit in the same order as FTL's forwarded count (somewhat higher, since
Unbound also absorbs FTL's stale-refresh and retry traffic). A sudden jump in
recursions/day with a flat FTL forwarded count points at FTL's cache, not at
Unbound.

### Write-Cadence Ladder

`5 s` dirty flusher | `30 s` dirty-expire = `30 s` ext4 commit | `600 s` FTL
`DBinterval` = `600 s` timesyncd `SaveIntervalSec` — storage writes coalesce
onto shared boundaries instead of scattering.

## Scheduled Maintenance

| Timer | Schedule | Purpose |
| --- | --- | --- |
| `dns-health-check.timer` | 2 min after boot, then every 23 h (rotating hour) | Full stack health + observability snapshot |
| `net-snapshot.timer` | 5 min after boot, then hourly | Kernel network counters (`nstat`) + socket summary/listeners (`ss`) to `/var/log/net-snapshot.log`; one `snapshot …` record per run in journald |
| `power-report.timer` | 5 min after boot, then hourly | Throttle flags, PMIC rail power, temperatures, energy forecast to `/var/log/power-report.log`; one `trend …` record per run in journald |
| `pihole-gravity.timer` | Sun 03:00 + up to 4 h jitter, `Persistent=true` | Weekly blocklist refresh |
| `pihole-logflush.timer` | Daily 00:10 + 30 min jitter | Rotates the Pi-hole query log via Pi-hole's own logrotate config |

The two Pi-hole timers were added after a build whose unattended installer
left no working `/etc/cron.d/pihole` (12 days of runtime with zero cron
activity — stale blocklists and an unbounded query log). On the current build
the installer does create the cron file and `cron.service` runs, so gravity
and the log flush execute twice (cron at 00:00 / Sunday 03–05 h, the timers
shortly after). Harmless but wasteful; see
`private/boot-log-assessment-2026-09-27.md` §2.1 for the dedupe options
(preferred: keep the timers, strip the two cron lines after install).

```bash
# Inspect all maintenance and monitoring timers
systemctl list-timers 'pihole-*' 'dns-*' 'net-snapshot*' 'power-report*'
```

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

# Bootloader EEPROM: installed vs the channel's latest (the boot-time service applies
# critical minimums only); stage an update deliberately, then reboot to flash
eeprom-update.sh
sudo eeprom-update.sh --apply
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

# Review Unbound cache behavior (hits/misses plus stale-serves and prefetches)
unbound-control stats_noreset | grep -E 'total\.num\.cachehits|total\.num\.cachemiss|total\.num\.expired|total\.num\.prefetch'

# Check CPU governor state (expected: schedutil, set via cmdline.txt)
grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null
```

The daily health check logs all of this automatically: unbound recursions
per day with prefetch and expired-served counts, unbound version + dpkg diversion
count, gravity blocklist age, FTL 24 h cached/forwarded split with the
client-perceived cache ratio, NTP sync state + port-123 listener, and SoC
throttle state.

## Troubleshooting

### SSH Debugging Quick Reference

For validating remote login when testing a freshly flashed host:

```bash
# Effective server config as sshd actually resolved it (drop-ins included)
sudo sshd -T | grep -Ei 'addressfamily|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods|kbdinteractive'

# Validate config syntax before restarting sshd
sudo sshd -t

# Confirm sshd is listening on the expected (static) address only
ss -tlnp | grep ':22'

# Watch auth attempts server-side while a client connects
sudo journalctl -u ssh -f

# Client side: verbose handshake shows which auth methods are offered/tried
ssh -vv localadmin@192.168.0.53
```

Notes:

- `ListenAddress` binds only the static LAN IP, and `ssh.service` waits for
  `network-online.target` — if the address is wrong or the link is down, sshd
  will be unreachable or fail to bind. Check `systemctl status ssh` and the
  journal first.
- Key logins require correct permissions on the target: `~/.ssh` 700,
  `~/.ssh/authorized_keys` 600, home directory not group-writable.
- The build injects the build user's `id_ed25519.pub` into `authorized_keys`
  via `SSH_PUBKEY_USER1`; verify with `cat ~/.ssh/authorized_keys` on the host.
- When re-testing key-only mode, uncomment `PubkeyAuthentication yes` and
  `AuthenticationMethods publickey` in
  `etc/ssh/sshd_config.d/local_network_only.conf` — and update the matching
  assertions in `scripts/pre-release-check.sh`, which pins the current
  commented state.

### Common Issues

1. **DNS not resolving**: Check service status and port conflicts
2. **Slow resolution**: Verify upstream DNS servers
3. **Local domains not working**: Check Avahi configuration and mDNS setup
4. **Pi-hole not blocking**: Update blocklists and check configuration
5. **Intermittent client connectivity**: Ensure only one DHCP server is active (Pi-hole OR router)
6. **Blocklists stale**: Check `systemctl status pihole-gravity.timer` and the health check's gravity-age line
7. **Clients using vendor time servers**: DHCP option 42 applies at lease renewal (up to ~24 h); Windows ignores it by default and needs manual configuration

### Log Locations

- Pi-hole (v6): `/var/log/pihole/pihole.log` (rotated daily by `pihole-logflush.timer`) and `/var/log/pihole/FTL.log` (rotates at FTL startup, as does `webserver.log`)
- Health check: `/var/log/dns-health.log` — self-rotates at 256 KiB, one previous generation kept (~512 KiB ceiling); journald holds the primary copy (`journalctl -u dns-health-check`)
- Network snapshot: `/var/log/net-snapshot.log` — the full hourly `nstat`/`ss` dump, self-rotates at 2 MiB (about two weeks) with one previous generation; journald carries only the one-line `snapshot ts=… udp_in=… tcp_retrans=…` record per run (`journalctl -u net-snapshot`), absolute counters since boot, so two records give the load or loss in between
- Power report: `/var/log/power-report.log` — the full hourly report, self-rotates at 2 MiB (about a month) with one previous generation; journald carries only the one-line `trend ts=… rail_w=… est_w=…` record per run (`journalctl -u power-report`). Weekly average: see the awk one-liner in the script header
- Unbound: `journalctl -u unbound` (file logging disabled: `verbosity: 0`, no `logfile` configured)
- Avahi: `journalctl -u avahi-daemon`
- systemd-resolved: `journalctl -u systemd-resolved`
- journald itself is size-capped by its defaults (persistent storage, ~10% of the filesystem)

### Collecting Logs for Review

From any LAN host with SSH access, `home/scripts/network/collect-appliance-logs.sh <appliance>`
pulls the current boot's journal, the Unbound cache dump and a `tar.gz` of the three monitor
logs plus a host-facts snapshot (card, sectors written, failed units, timers, versions, apt
history) into `private/inbox/`, then prints a one-screen review (failed units, health ⚠/✗,
under-voltage, SSH password logins, last health verdict, last `trend` and `snapshot`
records). `--since-last` makes the journal incremental for a weekly cron. The cache dump
needs root on the appliance; the script header shows the single-command sudoers line for
unattended runs, and everything else is collected without it. All monitoring pieces are
installed by `layer/ke-25-monitor.yaml`, which also puts the collector itself in
`/usr/local/bin` (`~/scripts/`) on the appliance.

## Backup and Recovery

### Backup Targets

- `/etc/pihole/`
- `/etc/unbound/`
- `/etc/avahi/`
- `/etc/systemd/resolved.conf.d/`
- `/etc/systemd/network/`
- `/etc/systemd/timesyncd.conf.d/`

### Manual Backup Command

```bash
sudo tar -czf /var/backups/ke-net-screen-config-$(date +%F).tgz \
 /etc/pihole /etc/unbound /etc/avahi /etc/systemd/resolved.conf.d \
 /etc/systemd/network /etc/systemd/timesyncd.conf.d
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

1. Inspect health-check service output:

```bash
sudo journalctl -u dns-health-check.service -n 200 --no-pager
```

1. Validate resolver behavior:

```bash
dig @127.0.0.1 github.com
dig @127.0.0.1 pi-hole.net
```

1. If needed, restart the stack:

```bash
sudo systemctl restart systemd-resolved unbound pihole-FTL avahi-daemon
```
