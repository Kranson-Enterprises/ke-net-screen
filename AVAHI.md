# Avahi (mDNS / DNS-SD) on the Appliance

Reference for `etc/avahi/avahi-daemon.conf`: what each option does, the avahi default, the
value this image ships and why, and what changes if you change it. The settings were tuned
deliberately; this page explains them rather than proposing new ones.

## What Avahi Does Here

- Answers multicast DNS for the appliance's own name (`<hostname>.local`) on the LAN
  interface, and publishes one service: "Pi-hole Server on `<hostname>`" (`_http._tcp`,
  port 80, from `/etc/avahi/services/http.service`).
- Gives glibc `.local` lookups through `mdns4_minimal` (see the NSS table in `README.md`)
  and lets the health check verify mDNS resolution with `avahi-resolve`.
- Takes no part in client DNS: Pi-hole and Unbound answer the LAN on port 53.

The appliance has one interface (`eth0`) with IPv4 addresses only — layer `ke-05` writes
`/etc/systemd/network/01-eth0.network` with `LinkLocalAddressing=no` — so avahi joins mDNS
on `eth0.IPv4` alone.

## How the File Reaches the Image

| Piece | Source | Notes |
| --- | --- | --- |
| `/etc/avahi/avahi-daemon.conf` | `etc/avahi/avahi-daemon.conf` | Layer `ke-20` copies it and substitutes `IGconf_device_hostname`, `IGconf_network_domain`, `IGconf_network_interface`, `IGconf_network_ipaddress` |
| `/etc/avahi/services/http.service` | Written by layer `ke-20` | The "Pi-hole Server" advertisement (`_http._tcp`, port 80) |
| `avahi-daemon.service.d/ke-restart.conf` | `etc/systemd/system/avahi-daemon.service.d/` | `Restart=on-failure`, `RestartSec=5`, matching FTL and Unbound |
| `/etc/nsswitch.conf` | `etc/nsswitch.conf` (also `ke-20`) | `mdns4_minimal [NOTFOUND=return]` before `dns` |

## Configured vs Configurable

Defaults are from `avahi-daemon.conf(5)` for avahi 0.8 (Debian trixie ships 0.8-16).
"Debian file" means the value Debian's packaged config sets where it differs from the
compiled default.

### [server]

| Option | Avahi default | This image | Why | Effect of changing |
| --- | --- | --- | --- | --- |
| `host-name` | system host name | `IGconf_device_hostname` | The build's host name, explicit | Another mDNS name than the system's |
| `host-name-from-machine-id` | no | not set (no) | — | `yes` publishes the machine-id as the name |
| `domain-name` | `local` | `local` | Standard mDNS domain | Anything but `.local` is outside the mDNS standard |
| `browse-domains` | none (plus default and announced) | `IGconf_network_domain` (the LAN's DNS domain) | Wide-area DNS-SD browsing of the LAN domain; needs `enable-wide-area=yes` | Removing it stops unicast DNS-SD browse queries for that domain |
| `use-ipv4` | yes | yes | mDNS runs over IPv4 here | `no` = no mDNS at all on this host |
| `use-ipv6` | yes | yes | Part of the image's IPv6 posture | With no IPv6 address on `eth0` the IPv6 side sees nothing today |
| `allow-interfaces` | all except loopback and point-to-point | `IGconf_network_interface` (`eth0`) | Only the LAN NIC | Adding an interface (e.g. Wi-Fi) gives the reflector a second network |
| `deny-interfaces` | none | not set | — | Takes precedence over `allow-interfaces` |
| `check-response-ttl` | no | no (explicit) | Compatibility with current mDNS stacks | `yes` drops packets whose IP TTL is not 255: extra protection, may break some peers |
| `use-iff-running` | no | not set (no) | Driver support is uneven | `yes` announces only while the link is up |
| `enable-dbus` | yes | yes | `avahi-resolve` / `avahi-browse` (used by the health check) talk D-Bus | `no` breaks those tools |
| `disallow-other-stacks` | no | **yes** | Only avahi may bind UDP 5353 | `no` lets another mDNS stack bind the port |
| `allow-point-to-point` | no | not set (no) | — | `yes` would offer mDNS on PtP links (security risk) |
| `cache-entries-max` | 4096 | 4096 | Default, stated explicitly | Memory vs. very large LANs |
| `clients-max` | 4096 | 4096 | Default, stated explicitly | Concurrent D-Bus clients |
| `objects-per-client-max` | 1024 | 1024 | Default, stated explicitly | Per-client browsers/resolvers |
| `entries-per-entry-group-max` | 32 | 32 | Default, stated explicitly | Records per published group |
| `ratelimit-interval-usec` / `ratelimit-burst` | no compiled value stated; Debian file 1000000 / 1000 | 1000000 / 1000 | Caps packets avahi generates per interface at 1000 per second | Lower = less amplification potential, more risk of dropped answers |

### [wide-area]

| Option | Avahi default | This image | Why | Effect of changing |
| --- | --- | --- | --- | --- |
| `enable-wide-area` | yes in 0.8-16 (Debian made `no` the default from 0.8-17) | yes | `browse-domains` relies on it | `no` stops unicast DNS-SD for non-`.local` domains and closes the CVEs below |

**Security note.** Debian's tracker lists trixie's avahi 0.8-16 as vulnerable to
CVE-2024-52615 (wide-area lookups reuse one constant source port) and CVE-2024-52616
(predictable transaction IDs), both "no-dsa, minor issue", with `enable-wide-area=no` as the
stated mitigation. On this image the engine holds one fixed-port UDP socket per address
family for the daemon's lifetime (see Sockets). avahi-daemon takes its unicast servers from
`/etc/resolv.conf` (Pi-hole first), Pi-hole answers the LAN domain locally, and nothing on a
typical home LAN publishes wide-area DNS-SD, so the feature has little to do here. The
setting is kept as tuned; switching it to `no` is the one-line mitigation if wanted.

### [publish]

| Option | Avahi default | This image | Why | Effect of changing |
| --- | --- | --- | --- | --- |
| `disable-publishing` | no | not set (no) | — | `yes` = query-only: no `.local` name, no service |
| `disable-user-service-publishing` | no | not set (no) | — | `yes` stops D-Bus clients publishing services |
| `add-service-cookie` | no | not set (no) | — | Adds a random TXT cookie to local services |
| `publish-addresses` | yes | yes | `<hostname>.local` resolves | `no` breaks the health check's mDNS test |
| `publish-hinfo` | no | no | Privacy: no OS/CPU record | — |
| `publish-workstation` | no (Debian file: yes) | no | No `_workstation._tcp` advertisement | — |
| `publish-domain` | yes | yes | Announces the browse domain | — |
| `publish-dns-servers` | none | `IGconf_network_ipaddress` (the appliance) | Announces the appliance as unicast DNS server over mDNS (read only by `avahi-dnsconfd` clients) | No effect on DHCP clients, which get the appliance from DHCP anyway |
| `publish-resolv-conf-dns-servers` | no | no | `/etc/resolv.conf` also lists the fallback resolvers; they must not be advertised | `yes` would announce `NETWORK_DNS1`/`NETWORK_DNS2` too |
| `publish-aaaa-on-ipv4` | yes | no | No cross-family records (there is no IPv6 address to publish anyway) | — |
| `publish-a-on-ipv6` | no | no | — | — |

### [reflector]

| Option | Avahi default | This image | Why | Effect of changing |
| --- | --- | --- | --- | --- |
| `enable-reflector` | no | yes | Prepared for bridging mDNS between networks (for example a second interface such as Wi-Fi) | **Inert today**: one interface, IPv4 only, so there is nothing to reflect between. Still opens two legacy-unicast sockets |
| `reflect-ipv` | no | yes | Reflect between IPv4 and IPv6 | Inert today (no IPv6 address); the man page calls it "usually not recommended" |
| `reflect-filters` | all services | 7 service types (below) | Only these are reflected once the reflector has two networks | See Reflector Filtering |

The reflector becomes live as soon as avahi sees a second network: another interface in
`allow-interfaces`, or an IPv6 address on `eth0` (with `reflect-ipv=yes`).

### [rlimits]

All lines are commented, as in Debian's file, so avahi leaves the system resource limits
unchanged. Debian's commented suggestions — `rlimit-core=0`, `rlimit-data=8388608`,
`rlimit-fsize=0`, `rlimit-nofile=768`, `rlimit-stack=8388608`, `rlimit-nproc=3` — would bound
the daemon further; avahi already runs as user `avahi`, chrooted, with its capabilities
dropped.

## Reflector Filtering

**How an entry matches** (avahi-core `server.c`, `handle_response_packet`):

- Applied to reflected **responses** only; queries are not filtered, and records arriving
  from a local interface skip the filter.
- **PTR** records are compared by their *target* (`record->data.ptr.name`), **SRV** and
  **TXT** records by their *owner name*. A, AAAA and other types are not filtered.
- The comparison is a plain **substring** test (`strstr`). A record that matches no entry
  is neither reflected nor cached.

So an entry has to occur literally inside names such as
`My Printer._ipps._tcp.local`. Writing the full `_service._proto.local` keeps a match
specific; `_ipp._tcp.local` would not match `_ipps._tcp.local`, and vice versa.

| Entry | Service | Typical devices |
| --- | --- | --- |
| `_airplay._tcp.local` | AirPlay video / screen mirroring | Apple TV, AirPlay-capable TVs, Macs |
| `_raop._tcp.local` | AirPlay audio (Remote Audio Output Protocol) | Apple TV, AirPlay speakers, TVs |
| `_ipps._tcp.local` | IPP over TLS (AirPrint / driverless printing) | Network printers |
| `_printer._tcp.local` | LPD/LPR printing | Older network printers |
| `_googlecast._tcp.local` | Google Cast | Chromecast, Google/Android TV, cast-enabled TVs |
| `_https._tcp.local` | HTTPS web interfaces | Printer, NAS and appliance admin pages |
| `_smb._tcp.local` | SMB file sharing | NAS, PCs with shared folders |

Not in the list, so not reflected if the reflector ever bridges networks: plain IPP
(`_ipp._tcp`, which most printers advertise next to `_ipps`), `_http._tcp` (including this
appliance's own "Pi-hole Server"), `_companion-link._tcp`, `_googlezone._tcp`,
`_spotify-connect._tcp`, `_hap._tcp` (HomeKit), `_matter._tcp`, `_device-info._tcp`.

History: until 2026-11 the SMB entry read `_smb.tcp.local` (no underscore before `tcp`) and
could never match; it was corrected without any change in behaviour, since the reflector is
inert.

## Sockets Avahi Holds

| UDP socket | Opened because of | Notes |
| --- | --- | --- |
| 5353 (IPv4 and IPv6) | mDNS itself | Exclusive (`disallow-other-stacks=yes`) |
| 2 × random port (IPv4, IPv6) | `enable-reflector=yes` | Legacy-unicast reflection sockets, open even while the reflector is inert |
| 2 × random port (IPv4, IPv6), fixed for the daemon's lifetime | `enable-wide-area=yes` | 0.8-16 keeps one socket per family (CVE-2024-52615); newer upstream opens one per lookup |

Observed on the appliance (owner `avahi`); the attribution follows avahi's source
(`server.c` `setup_sockets`, `wide-area.c`).

## Checking It

```bash
avahi-resolve -n "$(hostname).local"   # the appliance's own name
avahi-browse -art                       # everything visible on the LAN (Ctrl-C to stop)
sudo ss -uapn | grep avahi              # the sockets above
journalctl -u avahi-daemon -b           # "Joining mDNS multicast group on interface eth0.IPv4 ..."
```

The daily health check includes an mDNS resolution test; the collector's review shows
failures from it.
