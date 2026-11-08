# Security Policy

## Reporting a Vulnerability

Please report suspected vulnerabilities in this repository's code, layers, or shipped
configuration privately via **GitHub's private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability"). Do not open a public issue for a security report.

You can expect an acknowledgement within a week. Please include the release tag or commit,
what you observed, and reproduction steps if you have them.

## Scope

In scope: the ke-net-screen build system, layers, shipped configuration, and the scripts this
repository installs on the appliance (`home/scripts/`, `scripts/`).

Out of scope: vulnerabilities in the bundled third-party components themselves — report those
upstream (Pi-hole, NLnet Labs Unbound, Raspberry Pi rpi-image-gen); this project tracks their
releases through submodule updates. The README's **Security Posture** section documents the
appliance's deliberate security trade-offs (for example the opportunistic, self-signed
DNS-over-TLS tier) — these are design decisions, not vulnerabilities, though reports that
show a documented trade-off is more dangerous than stated are very welcome.

## Supported Versions

The latest tagged release is supported. Older tags receive no backports; upgrading is a
rebuild and reflash with your existing `.env`.
