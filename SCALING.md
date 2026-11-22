# Scaling the Appliance

This appliance was built for one household: about 25 reserved devices, 10–15 of them
active at a time, on one /24 behind a consumer ISP gateway. This page explains where its
limits are, what happens as the number of client devices grows, and how the network around
it (the router, the Wi-Fi, the way the network is split into segments) decides how well DNS
works long before the box itself runs out of anything.

None of this is a recommendation to change the household build. Its ceilings sit well
above anything it has measured. The page is for anyone who runs the image on a bigger
network, or who wants to know what a single small resolver can and cannot carry.

A single-board computer is also a scale model of larger network equipment. Every limit
described here (descriptor budgets, worker counts, queue depths, one network port, one
storage device, one power supply) exists in a purpose-built DNS appliance or an enterprise
firewall too, only further out and usually hidden. The section
[From Single-Board Computers to Purpose-Built Devices](#from-single-board-computers-to-purpose-built-devices)
maps one onto the other, so a measurement taken on this box means something on bigger
gear, and the reverse.

The numbers come from this repository's configuration, the effective values on a running
appliance (`unbound-checkconf -o`, `/proc/sys`, `ss -ltn`), and the compile-time constants
in Pi-hole FTL v6.9 (`src/dnsmasq/config.h`). Measurements are from the live appliance in
November 2026.

## What One Box Carries Today

| Measure | Value | Source |
| --- | --- | --- |
| Household load | ~0.3 queries/s on average (3,502 queries in 3.2 h from 10 active clients, about 0.03 queries/s per device) | Pi-hole statistics, 2026-11-22 |
| Tested throughput | 1.35–1.4k queries/s from one load source with no knee found; a multi-source test that would find the real ceiling has not been run | Load test, November 2026 |
| Headroom | roughly 400× the household's average load | the two rows above |
| Recursion time (cache miss) | average 0.25–0.31 s, median ~0.27 s; most recursions take 0.13–0.52 s | Unbound hourly statistics |
| Answered without recursion | about half: Pi-hole's cache plus blocked answers; Unbound's own cache hit rate is only 2–7% because Pi-hole answers repeats first | Pi-hole and Unbound statistics |
| Unbound request list | peak 21–90 entries of 512 per thread, never exceeded or jostled | Unbound statistics |
| CPU | 0.08% busy since boot; load average 0.00 | `/proc/stat` |
| Memory | 243–299 MiB used of 8 GiB | `free -m` across a week of collections |
| Power | ~2.5 W estimated input | `power-report.sh` |

The box is not the bottleneck at household scale, and it would not be at ten times that
scale either. What changes first as a network grows is the **shape** of the traffic
(more concurrent TCP and DoT connections, more clients behind one address, bigger
reconnection storms), not the query rate.

## The Request Path and Its Limits

Every query passes through a chain of components, and each one has its own limit. Plain
DNS over UDP and DNS over TCP/TLS (DoT) take different paths through the same box:

```text
UDP clients ──► FTL :53 (UDP) ──► Unbound 127.0.0.1:5335 ──► internet
                150 outstanding     512 queries/thread         960 UDP ports
                forwards            1 thread                   10 TCP to authorities

DoT clients ──► stunnel :853 ──► FTL :53 (TCP) ──► Unbound :5335 (TCP) ──► internet
                TLS, backlog 4096   1 worker process  40 incoming TCP
                ~500 clients by fd  per connection,   buffers (default 10),
                limit               at most 60;       1,024-fd select() loop
                                    backlog 32
```

| Rung | Limit | Where it is set | What happens at the limit |
| --- | --- | --- | --- |
| FTL forwards (UDP) | 150 outstanding queries to Unbound | `FTABSIZ` in FTL's dnsmasq; `dns-forward-max` | New cache misses are dropped and FTL logs "Maximum number of concurrent DNS queries reached (max: 150)"; clients retry after their timeout |
| FTL rate limit | 5,000 queries per 60 s **per client address** (Pi-hole's default is 1,000) | `dns.rateLimit` in `pihole.toml` | That client gets REFUSED until the interval ends |
| FTL TCP workers | 60 concurrent TCP connections, one forked process each; 32-entry listen backlog; at most 100 queries per connection | `MAX_PROCS`, `TCP_MAX_QUERIES` in FTL's dnsmasq; `max-tcp-connections` | New TCP connections wait in the backlog, and past 32 waiting connections the kernel drops them (`tcp_listen_overflow` in `net-snapshot.sh`) |
| FTL cache | 10,000 records | `dns.cache.size` | Older records are evicted; more queries go to Unbound |
| stunnel (DoT) | no connection cap; ~500 clients before the 1,024 soft descriptor limit (two descriptors per client) | systemd `LimitNOFILE` soft value | `accept` fails; the client's DoT connection is refused |
| Unbound incoming TCP | 10 by default, 40 with `UNBOUND_INCOMING_NUM_TCP=40` | `incoming-num-tcp` | FTL's TCP forward fails; the client receives REFUSED with Extended DNS Error 23 ("Network Error") |
| Unbound descriptors | 1,024 in all, because this build uses Unbound's internal `select()` event loop (mini-event) | build choice in `scripts/build-unbound.sh` | Caps `outgoing-range` + `incoming-num-tcp` + ~24 fixed descriptors at 1,024, which is why the toggle stops at 40 |
| Unbound queries | 512 per thread, 1 thread | `num-queries-per-thread`, `num-threads` | The oldest queries are jostled after 200 ms, then new ones are dropped (`requestlist exceeded`) |
| Unbound outbound | 960 UDP ports, 10 TCP connections to authoritative servers | `outgoing-range`, `outgoing-num-tcp` | Queries queue for a free port |
| Host | listen backlog cap 4,096 (`somaxconn`), SYN backlog 512, ephemeral ports 32768–60999, socket buffers up to 32 MiB | kernel defaults plus the image's sysctl files | Only relevant far above the rungs above |

### Ladder the Limits; Don't Align Them

Each rung should be at least as wide as the rung that feeds it, with headroom left for
traffic that does not come through the front door: health checks, the log collector,
clients that use plain DNS over TCP, retries after a truncated UDP answer. The narrowest
rung should be the first one. A refusal at the front door is cheap and clean, because the
client simply tries again or tries its next resolver. A refusal in the middle of the chain
turns into a confusing error for a query the front door already accepted.

Setting every rung to the same number ("aligning" them) looks tidy but breaks first:
any side traffic uses up a shared budget that has no slack left.

How the current build measures up:

- **The UDP path ladders correctly.** 150 outstanding forwards in FTL feed 512 query
  slots in Unbound, which feed 960 outbound ports.
- **The TCP/DoT path has one inversion.** FTL can run 60 TCP workers, but Unbound accepts
  40 TCP connections (10 by default). With more than 40 concurrent TCP or DoT clients, the
  41st forward is refused in the middle of the chain and the client sees REFUSED with
  EDE 23. The household runs 2–4 concurrent TCP workers. Before `incoming-num-tcp` went
  from 10 to 40 it still saw bursts of EDE 23 at busy moments, and none since.

If a deployment ever approaches 40 concurrent TCP/DoT clients, there are three ways to
close the inversion, in this order:

1. **Widen Unbound's rung above FTL's.** In the mini-event build the descriptor budget is
   `outgoing-range + incoming-num-tcp + ~24 ≤ 1,024`. That allows about 64 incoming TCP
   buffers if `outgoing-range` drops to ~936, which is still well above 512 queries per
   thread. Building Unbound against libevent removes the 1,024 cap altogether.
2. **Narrow FTL's rung below Unbound's** with the dnsmasq option `max-tcp-connections`
   (through `misc.dnsmasq_lines`). This trades the refusal for a wait: connections queue
   in FTL's 32-entry backlog, and a DoT client that waits feels slower than one that is
   refused and moves on. Use it only together with option 1, or for a short time.
3. **Change the model at real scale.** FTL's embedded dnsmasq forks one process per TCP
   connection; that is fine for dozens of connections and wrong for thousands. A
   connection-multiplexing DNS proxy in front (dnsdist, or Unbound terminating DoT itself)
   carries many client connections over a few upstream ones.

### Rate of Cache Misses (Little's Law)

The number of queries waiting on Unbound at any moment equals the rate of cache misses
times the average recursion time. With FTL's 150 outstanding forwards and a 0.3 s average
recursion, the UDP path sustains about **500 cache misses per second** before FTL starts
dropping. A slow upstream (an ISP problem, a congested uplink) shrinks that number in
direct proportion: at 1.5 s per recursion it is 100 per second. This is why upstream
latency, not CPU, is what a growing network notices first.

## Client Bands

Load estimates below use the household's measured 0.03 queries/s per device on average,
and assume short peaks of **20×** that average. Peaks come from boot storms, app
launches, and above all the moment after an outage when every device reconnects at once.
The estimates are a planning aid, not a measurement of any of these networks.

| Devices | Average load | Peak load (est.) | Peak share of tested throughput | What runs out first |
| --- | --- | --- | --- | --- |
| 10–20 | 0.3–0.6 q/s | 6–12 q/s | < 1% | Nothing on the box; Wi-Fi coverage and the gateway |
| 20–50 | 0.6–1.5 q/s | 12–30 q/s | ~2% | Unbound's default 10 incoming TCP buffers once DoT phones multiply |
| 50–100 | 1.5–3 q/s | 30–60 q/s | ~4% | The TCP/DoT inversion (40 vs 60); one DHCP scope; single point of failure |
| 100–250 | 3–7.5 q/s | 60–150 q/s | ~11% | The /24 address pool; broadcast and multicast load on one segment |
| 250–1,000 | 7.5–30 q/s | 150–600 q/s | up to ~45% | FTL's 150 outstanding forwards at the peaks; SD-card logging |
| 1,000–10,000 | 30–300 q/s | 0.6k–6k q/s | beyond one box | A single SBC; needs a resolver tier |
| 10,000–100,000 | 0.3k–3k q/s | 6k–60k q/s | beyond one box | Everything; this is campus or ISP resolver design |

### 10–20 Devices: the Household

What the image was built for. Every rung has 10× or more headroom.

- **What matters:** the gateway and the Wi-Fi. If the access point is part of the ISP
  gateway, as here, a gateway reboot takes every wireless device off the network,
  including its path to the appliance (see
  [Routers, Outages and Timing](#routers-outages-and-timing)).
- **What to watch:** nothing beyond the regular collection. The scheduled reboot takes
  DNS away for about 10 s (FTL answers ~9.8 s after the kernel starts) at 05:10 on a
  Sunday, which nobody notices.

### 20–50 Devices: a Busy House or a Small Office

Query rate is still trivial. The change is in connection count: every phone with Private
DNS (DoT) holds a TLS connection, and every one of those becomes an FTL TCP worker and,
under load, an Unbound TCP connection.

- **Set `UNBOUND_INCOMING_NUM_TCP=40`.** With the default 10, this household (about four
  DoT phones plus laptops) already saw EDE 23 REFUSED bursts at busy moments; 40 removed
  them.
- **Pi-hole's global "disable blocking" switch becomes a blunt tool.** A household opens
  the blocker for a few minutes when setting up a new account, and everyone shares that
  window. With 30 people it unblocks everyone to help one. Use Pi-hole groups to give one
  client an exception instead.
- **The access point, not the resolver, sets the experience.** Consumer gateways
  struggle with dozens of active wireless clients sharing airtime, and a lost UDP packet
  costs a Linux client a 5 s resolver timeout.

### 50–100 Devices: a Small Business, a Church, a School Wing

Still under 5% of tested throughput at the estimated peaks. Design questions take over.

- **The TCP/DoT inversion becomes reachable.** Over 40 concurrent TCP/DoT clients, apply
  the ladder fix above before users see "network error" answers.
- **One resolver is a single point of failure for many people.** Hand out a second
  resolver by DHCP, either a second appliance or a resolver whose filtering policy you
  accept. Clients move to the next server on timeout, SERVFAIL or REFUSED, but not on
  NXDOMAIN. Schedule maintenance reboots for when the building is empty.
- **One DHCP scope.** The /24 pool holds 253 addresses. 100 devices fit, but some phones
  can rotate their private MAC address, and each new address takes a new lease. Watch
  pool use and the 2-day lease time together.
- **Query history grows with the query count.** The query database is kept for 91 days
  by design, so it grows with every client. At this size, put it on a USB SSD rather
  than the SD card instead of shortening the history.
- **Routers that relay DNS hide the clients.** If a downstream router, a mesh base
  station or a guest-network NAT forwards its clients' DNS to the appliance, they all
  arrive from one address. Pi-hole then shows one client instead of fifty, per-client
  groups stop working, and the per-client rate limit (5,000 queries per minute, about
  83 per second) applies to the whole segment. Point clients at the appliance directly,
  or give the relaying router's address its own higher limit.

### 100–100,000 Devices: Segments and Tiers

Beyond 100 devices one flat network with one small resolver stops being the right
design, whatever the box can carry. The sub-bands differ in kind:

| Devices | Shape of the network | DNS design |
| --- | --- | --- |
| 100–250 | The /24 is full. Split into segments (VLANs): staff, guests, devices that should not talk to each other | One resolver pair per site; DHCP per segment or through a relay; per-segment Pi-hole groups |
| 250–1,000 | Several segments, routed by a real router or firewall with headroom in its connection-tracking table | A resolver pair with Unbound built against libevent and several threads; query logs shipped off the box; monitoring with alerts, not weekly reviews |
| 1,000–10,000 | A campus: many segments, managed switching, wireless controllers | Separate tiers: filtering front ends behind a shared address (VRRP or anycast), a recursive tier behind them, a TCP/DoT proxy that multiplexes connections, and load tests from many sources |
| 10,000–100,000 | An ISP or large campus | Resolver farms in several places, anycast, protection against amplification abuse, and per-subnet policy. A single-board computer has a place here only as a lab reference or a per-segment edge cache |

At 100,000 devices the estimated average load is ~3,000 queries/s and the peaks
~60,000. On raw throughput that is a few dozen boxes like this one. It would still be the
wrong design, because the hard problems at that size are redundancy, policy and
operations, not queries per second.

## From Single-Board Computers to Purpose-Built Devices

The same software stack (a filtering forwarder in front of a validating recursive
resolver) runs on hardware from a 512 MB board to a rack of servers. What changes with
the hardware is not what the software does but how far out each limit sits, and how many
of them are duplicated so one failure is not an outage.

### The Device Ladder

| Class | Typical example | Comfortable band | What sets its ceiling |
| --- | --- | --- | --- |
| Small single-board computer | Pi Zero 2 W (512 MB, Wi-Fi only), Pi 3B+ (1 GB, Ethernet over USB 2.0) | 10–20 devices | RAM headroom for caches and list updates; a Wi-Fi-only resolver shares airtime with its own clients; SD-card endurance |
| Capable single-board computer (this appliance) | Pi 5, 8 GB, gigabit Ethernet, SD or NVMe | 10–100 devices | The software rungs in the table above: FTL's 60 TCP workers and 150 forwards, Unbound's 1,024-descriptor build; one of everything |
| Small x86 box or mini PC | 4–8 cores, SSD, one or two NICs | 100–1,000 devices, as a pair | Thread count and network port; redundancy only if you build the pair |
| Router or firewall with a DNS service | Business-class gateway or firewall | Per site, 50–1,000 devices | Usually forwarding and caching only; its connection-tracking table and CPU are shared with routing and inspection |
| Purpose-built DNS/DHCP appliance | Dedicated DNS/DHCP/IP-management appliances, often deployed in pairs | 1,000–100,000+ devices | Licensed capacity and the HA design; built for failover, logging and policy at scale |
| Resolver farm | Many servers behind anycast | ISP scale | Operations, not hardware |

A gigabit port is not the limit at any size this page covers. A thousand queries per
second is under 5 Mbit/s of DNS traffic. Even a Pi 3B+'s ~300 Mbit/s USB-attached
Ethernet carries far more DNS than its CPU and memory can answer. A Wi-Fi-only resolver
is a different matter: it competes for airtime with the clients it serves, which is the
worst place to put the one device everyone depends on.

### The Same Limit at Every Size

| Limit on this appliance | What a smaller board changes | What larger, purpose-built devices do instead |
| --- | --- | --- |
| Unbound's `select()` loop caps descriptors at 1,024 | Same cap; less RAM for `msg-cache` / `rrset-cache` (16 MiB each here) | `epoll`-based event loops, one resolver thread per core sharing the port (`so-reuseport`), descriptor budgets in the hundreds of thousands |
| FTL forks one process per TCP/DoT connection, 60 at most | Each worker costs RAM it can spare less of | A connection-multiplexing proxy (or TLS offload) holding thousands of client connections over a few upstream ones |
| 150 outstanding forwards, sized by upstream latency (Little's law) | Same; a slower CPU adds little, because recursion time is dominated by the internet | Same law, bigger queues, and several upstream paths so one slow link does not shrink everyone's capacity |
| One NIC, one segment | Possibly no wired port at all | Bonded or multi-queue NICs, a leg in each VLAN, or a DHCP relay so one service covers many segments |
| SD card holds the OS and 91 days of query history | Less endurance and capacity | SSDs with endurance ratings, query logs streamed to a central store |
| One box: a reboot is an outage (about 10 s here) | Same, with slower boots | Active/active pairs behind a shared address (VRRP or anycast), DHCP failover, upgrades one node at a time |
| One power supply on its own UPS | Same | Dual power supplies on separate feeds |
| A weekly collection reviewed by a person | Same tools | Telemetry with thresholds and alerts on the same signals: request-list overflow, TCP refusals, listen-queue drops, rate-limit hits |
| A per-client rate limit at 5,000 queries/minute | Same | Per-client and per-subnet policies, response-rate limiting against amplification abuse |

### Reading the Bridge Both Ways

- **Upward:** a measurement on this box predicts the same symptom on bigger gear. EDE 23
  REFUSED bursts here meant an inverted TCP rung. On an enterprise appliance the same
  symptom points at the same kind of limit, only it hides behind a licence tier or a
  connection table.
- **Downward:** a feature of bigger gear explains a gap in the small one. A failover
  pair on the big device is what "hand out a second resolver" means here. Streaming
  logs is what "move the query database off the SD card" means.
- **The ladder rule holds at every size:** narrowest rung first, each later rung at
  least as wide, headroom for side traffic. A purpose-built appliance is a small box
  whose rungs were laddered by its vendor and then duplicated.

## Routers, Outages and Timing

A home network has two boxes that matter. The gateway owns the default route, the NAT
table and, in this household, the Wi-Fi radios. The appliance owns DHCP and DNS. Each
can fail without the other, and the client sees something different in each case.

### When the Router Restarts

ISPs push firmware to their gateways, and many gateways reboot to apply it, often
unannounced and sometimes in daytime. During that window:

- **Wireless clients lose the network entirely** if the access point is in the gateway.
  The appliance is up, but they cannot reach it.
- **Wired clients keep local service.** Local names and cached answers still resolve.
  Unbound serves expired records for up to a day (`serve-expired-ttl 86400`) when it
  cannot refresh them, and answers with the stale record if a refresh takes longer than
  1.8 s (`serve-expired-client-timeout 1800`), which keeps clients under their own
  timeouts.
- **Recursion for new names fails fast.** The appliance's outage signature is a burst of
  Unbound queries that fail in ~0.02 s, router advertisements dropping to zero,
  `v6_noroute` counts in the thousands per minute, and DoT connections stopping. It has
  ridden out every outage in this household without a failed service.
- **The return is the real load test.** When the gateway comes back, every device
  re-associates, renews its DHCP lease and re-resolves its names within a minute or two.
  That burst is where the 20× peak in the band table comes from, and it grows with the
  device count.

On a bigger network, keep the access points off the gateway, put the gateway, the
switches and the resolver on power that survives a short outage (separate UPSes are
fine), and schedule firmware upgrades yourself where the ISP allows it.

### Timing Budget

Users notice DNS as delay, and the delay comes from timeouts more than from work:

| Step | Typical time |
| --- | --- |
| Wired LAN round trip | < 1 ms |
| Wi-Fi round trip | 2–30 ms; more under airtime contention |
| Answer from Pi-hole's cache or a blocked name | well under 1 ms on the box |
| Recursion by Unbound | 0.1–1 s; median ~0.27 s here |
| DoT connection setup (TLS 1.3, one round trip) | one extra round trip per new connection; long-lived connections amortise it |
| A lost UDP query on a Linux client (glibc defaults) | 5 s before the retry |

One lost packet costs more than a thousand cache hits. As a segment grows, Wi-Fi
contention and loss grow with it, and the clients' 5 s timeouts become the "slow
internet" people report, even though the resolver is idle.

### What to Measure Per Segment

Before adding clients or splitting a network, measure each segment:

- **Client count and peak queries/s**: Pi-hole statistics.
- **Concurrent TCP/DoT connections**: FTL worker processes, Unbound's incoming TCP use,
  `tcp_listen_drop` / `tcp_listen_overflow` in `net-snapshot.sh`.
- **Resolver saturation**: Unbound's `requestlist exceeded` and `jostled` in the hourly
  statistics; FTL's "Maximum number of concurrent DNS queries reached" message;
  REFUSED answers with EDE 23.
- **Packet loss to the resolver**: `udp_rcvbuf_err` and `udp_in_err` on the appliance,
  plus round trip and loss from a client on that segment.
- **DHCP pool use and lease churn**: the lease file and FTL's DHCP log.
- **Broadcast and multicast load**: mDNS reflection, ARP, and the LAN-wide non-IP
  frames that show up as `eth0` RX `dropped` (about one per second here, a property of
  the LAN, not loss).
- **Where the segment's DNS really goes**: straight to the resolver, or through a router
  that relays it.

`home/scripts/network/collect-appliance-logs.sh` gathers most of these in one pass.

## What the Hardening Costs

v0.3.9 tightens the kernel and the network stack. Strict reverse-path filtering now
covers every interface, and IPv6 redirects are ignored. Three kernel features the
appliance never uses are switched off: legacy TIOCSTI terminal injection, automatic
line-discipline loading and io_uring.

These are switches, not filters that run for each query, so they cost nothing measurable:

- **Memory:** 279–299 MiB used before the hardening (v0.3.8) and 243–279 MiB with all of
  it in place. The range is set by uptime and Pi-hole's in-memory history, not by the
  settings.
- **CPU and power:** 0.08% CPU busy since boot, load average 0.00, ~2.5 W, unchanged.
- **Reverse-path filtering** adds one route lookup per received packet. At household
  rates (~7 packets/s on average) that is unmeasurable, and it stays negligible at
  thousands of packets per second. It has dropped 0 packets since boot, so the LAN is
  currently clean. The setting is insurance against spoofed traffic, not a cleanup.
- **Post-quantum key exchange** (hybrid ML-KEM-768 with X25519 for SSH, and first in the
  DoT key-exchange list) adds about 1 KB to each full handshake and well under a
  millisecond of CPU. DoT connections are long-lived, so the cost per query is
  effectively zero.
- **The one real allocation** is Unbound's 40 incoming TCP buffers instead of 10.
  Unbound reserves those 30 extra buffers at start-up, about 2 MiB at 64 KiB each.

Only reverse-path filtering grows with traffic, and slowly, so the hardening carries to
the larger bands unchanged.

## See Also

- [CONFIG-OVERVIEW.md](CONFIG-OVERVIEW.md): how the configuration reaches the image, and
  the toggles named here (`UNBOUND_INCOMING_NUM_TCP`, `DOT_TERMINATOR`,
  `DOT_TLS_HARDENING`, `SYSCTL_HARDENING`).
- [README.md](README.md): the request path, the DoT terminator and the maintenance schedule.
