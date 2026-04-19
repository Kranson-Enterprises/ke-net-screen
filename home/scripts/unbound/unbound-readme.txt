# Unbound DNS Management Scripts

This directory contains a collection of utility scripts for managing and monitoring your Unbound DNS resolver installation. These scripts are designed to work with a Pi-hole + Unbound DNS infrastructure.

## Available Scripts

### 📊 unbound-stats - DNS Statistics Display
Displays comprehensive statistics from the Unbound DNS resolver including performance metrics, cache hit rates, and query statistics.

**Basic Usage:**
```bash
# Show formatted statistics display
./unbound-stats

# Continuous monitoring (updates every 5 seconds) 
./unbound-stats --watch

# Save statistics to timestamped file
./unbound-stats --output

# Save to specific filename
./unbound-stats --file mystats.txt

# Show raw unformatted output
./unbound-stats --raw

# Quiet mode (minimal output)
./unbound-stats --quiet

# Display help information
./unbound-stats --help
```

### 💾 unbound-cache - Cache Management
Dumps the current Unbound DNS cache to a timestamped file for analysis and backup purposes.

**Basic Usage:**
```bash
# Dump cache to timestamped file in home directory
./unbound-cache

# Dump cache without viewing prompt
./unbound-cache --no-view

# Quiet mode operation
./unbound-cache --quiet

# Display help and usage information
./unbound-cache --help
```

**Output:** Creates file named `dns-cache-as-of-YYMMDD-HH-MM.txt` in your home directory

### 🔧 unbound-config - Configuration Viewer
Displays active (non-comment) configuration lines from Unbound configuration files, filtering out comments and empty lines.

**Basic Usage:**
```bash
# Show active configuration lines only
./unbound-config

# Show complete config including comments
./unbound-config --all

# Show verbose information with file statistics
./unbound-config --verbose

# Show only main config file (not includes)
./unbound-config --file

# Display help information
./unbound-config --help
```

### 📋 unbound-journal - Service Logs & Configuration
Displays the current Unbound configuration and recent service logs for troubleshooting.

**Basic Usage:**
```bash
# View Pi-hole specific config and service logs
./unbound-journal
```

**What it shows:**
- Pi-hole Unbound configuration file (`/etc/unbound/unbound.conf.d/pi-hole.conf`)
- Recent Unbound service journal entries with detailed error information

### 🧪 unbound-test - DNS Functionality Testing
Performs DNS resolution tests to verify Unbound is working correctly with DNSSEC validation.

**Basic Usage:**
```bash
# Run comprehensive DNS tests
./unbound-test
```

**Tests performed:**
- `dig pi-hole.net @127.0.0.1 -p 5335` - Test basic DNS resolution
- `dig fail01.dnssec.works @127.0.0.1 -p 5335` - Test DNSSEC failure handling
- `dig dnssec.works @127.0.0.1 -p 5335` - Test successful DNSSEC validation
- Check unbound-resolvconf service status

### 🔄 unbound-reset - Complete DNS Stack Reset
Resets the entire DNS infrastructure including Pi-hole database, caches, and statistics. Use with caution!

**Basic Usage:**
```bash
# Perform complete DNS infrastructure reset
./unbound-reset
```

**Operations performed:**
1. Clear systemd-resolved caches and statistics
2. Show current Pi-hole database size
3. Flush Pi-hole DNS cache and logs
4. Stop Pi-hole FTL service
5. Delete and recreate Pi-hole FTL database
6. Restart Pi-hole FTL service
7. Show new database size after reset

**⚠️ Warning:** This script will clear all Pi-hole query history and statistics!

## Common Use Cases

### 🔍 Troubleshooting DNS Issues
```bash
# Check if Unbound is working properly
./unbound-test

# View current configuration
./unbound-config

# Check service logs for errors
./unbound-journal

# View real-time statistics
./unbound-stats --watch
```

### 📈 Performance Monitoring
```bash
# Monitor DNS performance continuously
./unbound-stats --watch

# Save daily statistics report
./unbound-stats --file daily-stats-$(date +%Y%m%d).txt

# Check cache efficiency
./unbound-cache --quiet
```

### 🧹 Maintenance Tasks
```bash
# Backup current cache
./unbound-cache

# Reset everything if having issues
./unbound-reset

# Verify operation after changes
./unbound-test
```

## Prerequisites

- Unbound DNS resolver installed and running
- Pi-hole FTL service (for reset script)
- Appropriate permissions (some commands may require sudo)
- Standard Unix utilities: dig, journalctl, systemctl

## File Permissions

Make scripts executable:
```bash
chmod +x unbound-*
```

## Integration with System Monitoring

These scripts can be integrated into monitoring systems or cron jobs:
```bash
# Add to crontab for daily statistics
0 6 * * * /path/to/unbound-stats --output --quiet

# Weekly cache backup
0 2 * * 0 /path/to/unbound-cache --quiet --no-view
```

For more detailed help on any script, use the `--help` option.
