#!/usr/bin/env python3
"""ke-net-screen network test battery.

Run from a LAN host against the deployed appliance. Read-only; no root
required. Pure stdlib. Sized for a quiet network (~2 minutes total).

Usage:
    ./dns-battery.py [target-ip]        # default 192.168.0.53

Sections:
    1  port surface (5335/8953 must be unreachable from the LAN)
    2  latency battery (cache hit / cold NXDOMAIN / real / blocked)
    3  DNSSEC (AD bit on valid + SERVFAIL on bogus)
    4  TCP path + TCP Fast Open probe
    5  NTP service quality + jitter
    6  dns64 / rebinding / negative-cache / CNAME / PTR-leak / ANY
    7  posture (informational, before the burst so rate limiting cannot colour it):
       WPAD regex state, admin HTTP->HTTPS redirect, TLS cert expiry
    8  30 s sustained burst (~170 qps)

Expected results per deployment are tracked in
private/release-notes-*.md (post-deployment validation).
"""
import os
import random
import ssl
import tempfile
import socket
import statistics
import string
import struct
import sys
import threading
import time

SERVER = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.53"
MSG_FASTOPEN = 0x20000000
FAILS = []


def note_fail(msg):
    FAILS.append(msg)


def build_query(name, qtype=1, do_bit=False):
    qid = random.randint(0, 65535)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 1 if do_bit else 0)
    for label in name.rstrip(".").split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", qtype, 1)
    if do_bit:  # EDNS0 OPT RR, DO flag, 1232B payload
        q += b"\x00" + struct.pack(">HHIH", 41, 1232, 0x00008000, 0)
    return qid, q


def parse_header(data):
    flags = struct.unpack(">H", data[2:4])[0]
    return {"rcode": flags & 0xF, "ad": bool(flags & 0x0020),
            "tc": bool(flags & 0x0200),
            "ancount": struct.unpack(">H", data[6:8])[0]}


def parse_answers(data):
    qd, an = struct.unpack(">HH", data[4:8])
    off = 12
    for _ in range(qd):
        while data[off] not in (0,) and data[off] < 0xC0:
            off += 1 + data[off]
        off += 1 if data[off] == 0 else 2
        off += 4
    out = []
    for _ in range(an):
        if off >= len(data):
            break
        while off < len(data) and data[off] != 0 and data[off] < 0xC0:
            off += 1 + data[off]
        off += 1 if (off < len(data) and data[off] == 0) else 2
        if off + 10 > len(data):
            break
        rtype, _, _, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        out.append((rtype, data[off:off + rdlen]))
        off += rdlen
    return out


def udp_query(name, qtype=1, do_bit=False, timeout=4.0, want_answers=False):
    qid, q = build_query(name, qtype, do_bit)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t0 = time.monotonic()
    try:
        s.sendto(q, (SERVER, 53))
        while True:
            data, _ = s.recvfrom(4096)
            if struct.unpack(">H", data[:2])[0] == qid:
                r = parse_header(data)
                r["rtt"] = (time.monotonic() - t0) * 1000
                if want_answers:
                    try:
                        r["answers"] = parse_answers(data)
                    except (struct.error, IndexError):
                        r["answers"] = []
                return r
    except socket.timeout:
        return None
    finally:
        s.close()


def tcp_query(name, use_tfo=False, timeout=4.0):
    qid, q = build_query(name)
    payload = struct.pack(">H", len(q)) + q
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    t0 = time.monotonic()
    try:
        if use_tfo:
            s.sendto(payload, MSG_FASTOPEN, (SERVER, 53))
        else:
            s.settimeout(timeout)
            s.connect((SERVER, 53))
            s.sendall(payload)
        s.settimeout(timeout)
        resp = b""
        while len(resp) < 2:
            chunk = s.recv(4096)
            if not chunk:
                return None
            resp += chunk
        want = 2 + struct.unpack(">H", resp[:2])[0]
        while len(resp) < want:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
        r = parse_header(resp[2:])
        r["rtt"] = (time.monotonic() - t0) * 1000
        return r
    except OSError:
        return None
    finally:
        s.close()


def pct(vals):
    if not vals:
        return "n/a"
    vs = sorted(vals)
    p = lambda q: vs[min(len(vs) - 1, int(q * len(vs)))]
    return (f"p50={statistics.median(vs):.1f} p95={p(0.95):.1f} "
            f"p99={p(0.99):.1f} max={vs[-1]:.1f} ms (n={len(vs)})")


def fmt_ip(t, b):
    if t == 1 and len(b) == 4:
        return ".".join(map(str, b))
    if t == 28 and len(b) == 16:
        return socket.inet_ntop(socket.AF_INET6, b)
    return f"type{t}"


def rand_name(tld="com"):
    return "".join(random.choices(string.ascii_lowercase, k=14)) + "-kx." + tld


def tfo_active_counter():
    hdr = vals = None
    for line in open("/proc/net/netstat"):
        if line.startswith("TcpExt:"):
            if hdr is None:
                hdr = line.split()[1:]
            else:
                vals = line.split()[1:]
    d = dict(zip(hdr, map(int, vals)))
    return d.get("TCPFastOpenActive", 0)


def section(n, title):
    print("=" * 62)
    print(f"SECTION {n}: {title}")


section(1, f"sanity + TCP port surface ({SERVER})")
r = udp_query("debian.org")
if not r:
    sys.exit(f"FATAL: no DNS response from {SERVER}")
print(f"  sanity query: rcode={r['rcode']} rtt={r['rtt']:.1f}ms")
for port, label, must_be_closed in [(22, "ssh", False), (53, "dns-tcp", False),
                                    (80, "http", False), (443, "https", False),
                                    (2222, "alt-ssh", True), (3000, "gitea", True),
                                    (5335, "unbound", True),
                                    (8953, "unbound-ctl", True),
                                    (8080, "misc", True)]:
    s = socket.socket()
    s.settimeout(1.5)
    rc = s.connect_ex((SERVER, port))
    s.close()
    state = "OPEN" if rc == 0 else "closed"
    bad = must_be_closed and rc == 0
    if bad:
        note_fail(f"port {port} ({label}) unexpectedly open")
    print(f"  {port:5d} {label:12s} {state}{' <-- UNEXPECTED' if bad else ''}")

section(2, "latency battery (UDP)")
udp_query("google.com")
hits = [r["rtt"] for _ in range(60) if (r := udp_query("google.com"))]
print(f"  cache-hit    : {pct(hits)}")
nxs = []
for n in [rand_name(t) for t in ("com", "net", "org") for _ in range(8)]:
    r = udp_query(n)
    if r and r["rcode"] == 3:
        nxs.append(r["rtt"])
print(f"  cold NXDOMAIN: {pct(nxs)}")
REAL = ["kernel.org", "wikipedia.org", "python.org", "cloudflare.com",
        "netflix.com", "reddit.com", "bbc.co.uk", "nasa.gov", "gnu.org"]
reals = [r["rtt"] for n in REAL if (r := udp_query(n))]
print(f"  real domains : {pct(reals)}  (mixed warm/cold)")
blocked_rtt, blocked_name = [], None
for cand in ["ad.doubleclick.net", "doubleclick.net", "app-measurement.com"]:
    r = udp_query(cand, want_answers=True)
    if r and r["rcode"] == 0 and any(
            a[0] == 1 and a[1] == b"\x00\x00\x00\x00" for a in r.get("answers", [])):
        blocked_rtt = [p["rtt"] for _ in range(20) if (p := udp_query(cand))]
        blocked_name = cand
        break
print(f"  blocked ({blocked_name}): {pct(blocked_rtt)}")
if not blocked_name:
    note_fail("no test domain confirmed blocked (gravity empty?)")

section(3, "DNSSEC validation")
for name, expect in [("debian.org", "AD"), ("ietf.org", "AD"),
                     ("dnssec-failed.org", "SERVFAIL")]:
    r = udp_query(name, do_bit=True, timeout=8.0)
    if r is None:
        print(f"  {name:20s}: timeout")
        note_fail(f"DNSSEC probe {name} timed out")
        continue
    ok = (r["rcode"] == 2) if expect == "SERVFAIL" else (r["ad"] and r["rcode"] == 0)
    if not ok:
        note_fail(f"DNSSEC {name}: rcode={r['rcode']} AD={r['ad']} (expected {expect})")
    print(f"  {name:20s}: rcode={r['rcode']} AD={r['ad']}  "
          f"[{'PASS' if ok else 'FAIL'}] (expected {expect})")

section(4, "TCP path + TCP Fast Open")
tcps = [r["rtt"] for _ in range(15) if (r := tcp_query("google.com"))]
print(f"  plain TCP    : {pct(tcps)}")
a0 = tfo_active_counter()
ok1 = tcp_query("google.com", use_tfo=True) is not None
ok2 = tcp_query("google.com", use_tfo=True) is not None
delta = tfo_active_counter() - a0
print(f"  TFO          : conn1={'ok' if ok1 else 'fail'} conn2={'ok' if ok2 else 'fail'}, "
      f"client TFO-Active delta={delta} "
      f"({'data-in-SYN accepted' if delta > 0 else 'no TFO success observed'})")

section(5, "NTP service quality (5 samples)")
offs, ntprtts, stratum = [], [], None
for _ in range(5):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    t0 = time.time()
    try:
        s.sendto(b"\x1b" + 47 * b"\0", (SERVER, 123))
        data, _ = s.recvfrom(512)
        rtt = time.time() - t0
        stratum = data[1]
        tx = struct.unpack(">I", data[40:44])[0] - 2208988800 + \
            struct.unpack(">I", data[44:48])[0] / 2**32
        offs.append((tx - (time.time() - rtt / 2)) * 1000)
        ntprtts.append(rtt * 1000)
    except socket.timeout:
        pass
    finally:
        s.close()
    time.sleep(0.3)
if offs:
    print(f"  {len(offs)}/5 replies, stratum={stratum}, rtt avg={sum(ntprtts)/len(ntprtts):.2f}ms, "
          f"offset avg={sum(offs)/len(offs):+.1f}ms, jitter={max(offs)-min(offs):.2f}ms")
else:
    note_fail("no NTP response")
    print("  NO NTP RESPONSE")

section(6, "module + protection probes")
r6 = udp_query("ipv4only.arpa", 28, timeout=6.0, want_answers=True)
if r6:
    synth = any(fmt_ip(*a).startswith("64:ff9b::") for a in r6.get("answers", []))
    print(f"  dns64        : {'ACTIVE (64:ff9b::/96)' if synth else 'no synthesis observed'}")
for name in ["192.168.0.1.nip.io", "10.0.0.1.nip.io"]:
    r = udp_query(name, timeout=6.0, want_answers=True)
    if r is None:
        print(f"  rebind {name:22s}: timeout")
        continue
    ips = [fmt_ip(*a) for a in r.get("answers", []) if a[0] == 1]
    leaked = [ip for ip in ips if ip.startswith(("192.168.", "10.", "169.254."))]
    if leaked:
        note_fail(f"rebinding protection leaked {leaked} for {name}")
    print(f"  rebind {name:22s}: {'LEAKED <-- FAIL' if leaked else 'stripped [PASS]'}")
n = rand_name()
r1, r2 = udp_query(n), udp_query(n)
if r1 and r2:
    print(f"  neg-cache    : first={r1['rtt']:.1f}ms second={r2['rtt']:.1f}ms "
          f"[{'PASS' if r2['rtt'] < 10 else 'slow'}]")
r = udp_query("www.microsoft.com", timeout=6.0, want_answers=True)
if r:
    ts = [a[0] for a in r.get("answers", [])]
    print(f"  cname-chain  : CNAMEs={ts.count(5)} A={ts.count(1)} rtt={r['rtt']:.1f}ms")
r = udp_query("250.0.168.192.in-addr.arpa", 12)
if r:
    ok = r["rtt"] < 10
    if not ok:
        note_fail("PTR for LAN address went upstream")
    print(f"  ptr-leak     : rcode={r['rcode']} rtt={r['rtt']:.1f}ms "
          f"[{'PASS - local' if ok else 'went upstream?'}]")
r = udp_query("google.com", 255, timeout=6.0)
if r:
    print(f"  ANY (255)    : rcode={r['rcode']} answers={r['ancount']} (minimal expected)")

section(7, "posture probes (informational: report policy state, never fail)")
# WPAD regex (PIHOLE_REGEX_DENY / wpad-block.sh): Pi-hole answers a regex-denied name with
# 0.0.0.0, so blocked beats NXDOMAIN - an answered name stops Windows' LLMNR/NetBIOS fallback.
wpad_states = []
for name in ["wpad.lan", "wpad.example.com"]:
    r = udp_query(name, timeout=6.0, want_answers=True)
    if r is None:
        wpad_states.append(f"{name}=timeout")
        continue
    ips = [fmt_ip(*a) for a in r.get("answers", []) if a[0] == 1]
    if any(ip in ("0.0.0.0", "::") for ip in ips):
        wpad_states.append(f"{name}=blocked")
    elif r["rcode"] == 3:
        wpad_states.append(f"{name}=nxdomain")
    elif r["rcode"] == 5:
        wpad_states.append(f"{name}=refused(rate-limited?)")
    else:
        wpad_states.append(f"{name}=rcode{r['rcode']}{ips}")
wpad_active = bool(wpad_states) and all("=blocked" in x for x in wpad_states)
wpad_unknown = any("refused" in x or "timeout" in x for x in wpad_states)
wpad_label = "ACTIVE" if wpad_active else ("undetermined" if wpad_unknown else "not active")
print(f"  wpad regex   : {wpad_label} ({', '.join(wpad_states)})"
      f"{'' if wpad_active or wpad_unknown else '  [sudo wpad-block.sh --on, or PIHOLE_REGEX_DENY in .env]'}")


def http_head(port, tls=False, path="/admin/"):
    sock = socket.create_connection((SERVER, port), timeout=5)
    if tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = ctx.wrap_socket(sock, server_hostname=SERVER)
    try:
        sock.sendall(f"HEAD {path} HTTP/1.0\r\nHost: {SERVER}\r\n\r\n".encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    finally:
        sock.close()
    lines = data.decode(errors="replace").split("\r\n")
    parts = lines[0].split(" ")
    status = parts[1] if len(parts) > 1 else "?"
    loc = next((h.split(":", 1)[1].strip() for h in lines[1:] if h.lower().startswith("location:")), "")
    return status, loc


try:
    st, loc = http_head(80)
    if loc.lower().startswith("https://"):
        print(f"  admin http   : {st} -> {loc}  [redirects to HTTPS]")
    else:
        print(f"  admin http   : {st} {loc or '(no Location)'}  [plain HTTP served; "
              f"webserver.port = \"80r,443s\" would redirect]")
except OSError as e:
    print(f"  admin http   : port 80 unreachable ({e})")

try:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((SERVER, 443), timeout=5) as raw, \
            ctx.wrap_socket(raw, server_hostname=SERVER) as tls_sock:
        der = tls_sock.getpeercert(binary_form=True)
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as pemf:
        pemf.write(ssl.DER_cert_to_PEM_cert(der))
        pem_path = pemf.name
    try:
        info = ssl._ssl._test_decode_cert(pem_path)  # stdlib's own PEM decoder (private API)
    finally:
        os.unlink(pem_path)
    cn = dict(x[0] for x in info.get("subject", ())).get("commonName", "?")
    days = (ssl.cert_time_to_seconds(info["notAfter"]) - time.time()) / 86400
    print(f"  admin tls    : CN={cn} expires {info['notAfter']} ({days:.0f} days)"
          f"{'  <-- renews/expires soon' if days < 14 else ''}")
except (OSError, ssl.SSLError, KeyError, ValueError) as e:
    print(f"  admin tls    : {e}")

section(8, "30s sustained burst (~170 qps, 80% repeat / 20% unique)")
pool = REAL + ["google.com", "github.com", "apple.com", "microsoft.com",
               "amazon.com", "debian.org"]
lat, errs, lock = [], [0], threading.Lock()
stop = time.monotonic() + 30


def worker():
    while time.monotonic() < stop:
        nm = random.choice(pool) if random.random() < 0.8 else rand_name()
        rr = udp_query(nm, timeout=2.0)
        with lock:
            if rr:
                lat.append(rr["rtt"])
            else:
                errs[0] += 1
        time.sleep(0.02)


threads = [threading.Thread(target=worker) for _ in range(5)]
t0 = time.monotonic()
for t in threads:
    t.start()
for t in threads:
    t.join()
dur = time.monotonic() - t0
total = len(lat) + errs[0]
loss = 100 * errs[0] / max(1, total)
if loss > 1.0:
    note_fail(f"burst loss {loss:.2f}% (>1%)")
print(f"  {total} queries in {dur:.1f}s = {total/dur:.0f} qps, "
      f"lost={errs[0]} ({loss:.2f}%)")
print(f"  latency      : {pct(lat)}")

print("=" * 62)
if FAILS:
    print(f"RESULT: {len(FAILS)} FAILURE(S)")
    for f in FAILS:
        print(f"  ✗ {f}")
    sys.exit(1)
print("RESULT: all checks passed")
