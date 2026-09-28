#!/bin/bash
# Build Unbound from the vendors/unbound submodule and stage artifacts so that
# the ke-08-unbsrccfg layer hook can install them into the image rootfs.
#
# Usage:
#   scripts/build-unbound.sh <OUTDIR> [options]
#
# Where OUTDIR is the ke-net-screen-build directory (same value as the OUTDIR
# variable in ke-net-screen.sh, e.g. ke-net-screen-build/).
#
# Build objects are cached in .unbound-build/ (project root, gitignored) so
# that incremental rebuilds are fast.  The install step always re-populates
# OUTDIR/build/staging/<gnu-type>/ because that tree is wiped on every full
# image build.
#
# Optional flags:
#   --with-pihole-conf-check
#     Stage and validate etc/unbound/unbound.conf.d/pi-hole.conf using the
#     staged unbound-checkconf binary. This confirms compile-time modules are
#     compatible with the runtime config.
#   --fresh-build
#     Delete existing .unbound-build cache before configure/build.
#   --no-prompt
#     Do not prompt when an existing build cache is detected.
#   --help
#     Show usage and options.
#
# Requires:
#   gcc, make, libssl-dev, libexpat1-dev
#   The vendors/unbound submodule to be checked out
#     (git submodule update --init vendors/unbound)

set -euo pipefail
IFS=$'\n\t'

# Running as root poisons the build cache and staging tree with root-owned
# files that later rootless builds cannot modify or remove. Refuse early.
if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: do not run this script with sudo/as root - the build is rootless." >&2
  echo "       Root-owned files in .unbound-build/ and the staging tree break" >&2
  echo "       subsequent unprivileged builds." >&2
  echo "       Flashing does not need a root build either: ke-net-screen.sh" >&2
  echo "       caches sudo once at the start and keeps it fresh for the" >&2
  echo "       post-build flash - answer the initial prompts, then walk away." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/build-unbound.sh <OUTDIR> [options]

Options:
  --with-pihole-conf-check  Validate staged pi-hole.conf using staged unbound-checkconf
  --fresh-build             Delete .unbound-build cache before configure/build
  --no-prompt               Reuse cache without interactive delete prompt
  --help                    Show this help text
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

OUTDIR="$1"
shift
# Normalize to an absolute path: make install runs from the build cache and
# libtool rejects a relative DESTDIR ("must be an absolute directory name").
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

WITH_PIHOLE_CONF_CHECK=0
FRESH_BUILD=0
NO_PROMPT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-pihole-conf-check)
      WITH_PIHOLE_CONF_CHECK=1
      shift
      ;;
    --fresh-build)
      FRESH_BUILD=1
      shift
      ;;
    --no-prompt)
      NO_PROMPT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
VENDOR_SRC="$PROJECT_ROOT/vendors/unbound"
BUILD_CACHE="$PROJECT_ROOT/.unbound-build"
GNU_TYPE="$(dpkg-architecture -qDEB_HOST_GNU_TYPE)"
STAGING_DIR="$OUTDIR/build/staging/$GNU_TYPE"
PIHOLE_CONF_SRC="$PROJECT_ROOT/etc/unbound/unbound.conf.d/pi-hole.conf"
CONF_MARKER="$BUILD_CACHE/.configured"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ ! -f "$VENDOR_SRC/configure" ]]; then
  echo "ERROR: $VENDOR_SRC/configure not found." >&2
  echo "Run: git submodule update --init vendors/unbound" >&2
  exit 1
fi

UNBOUND_VER="$("$VENDOR_SRC/configure" --version 2>/dev/null | awk 'NR==1{print $NF}')"
echo "==> Unbound $UNBOUND_VER  source: $VENDOR_SRC"
echo "==> Build cache: $BUILD_CACHE"
echo "==> Staging target: $STAGING_DIR"

# Optional TCP Fast Open server support (RFC 7413), opt-in via
# UNBOUND_ENABLE_TFO_SERVER=y in .env (the wrapper exports it) or the
# environment.  Compile-time only: the listener then sets TCP_FASTOPEN on
# its TCP sockets.  The kernel must also allow server-side TFO
# (net.ipv4.tcp_fastopen bit 0x2 - 99-unbound-tuning.conf sets 3).
UNBOUND_ENABLE_TFO_SERVER="${UNBOUND_ENABLE_TFO_SERVER:-n}"
EXTRA_CONFIGURE_ARGS=()
if [[ "${UNBOUND_ENABLE_TFO_SERVER,,}" =~ ^y(es)?$ ]]; then
  EXTRA_CONFIGURE_ARGS+=(--enable-tfo-server)
  echo "==> TCP Fast Open server support: enabled (--enable-tfo-server)"
fi

for dep_pkg in libssl-dev libexpat1-dev; do
  if ! dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "install ok"; then
    echo "ERROR: build dependency '$dep_pkg' is not installed." >&2
    echo "Run: sudo apt-get install -y $dep_pkg" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Build cache handling
# ---------------------------------------------------------------------------
if [[ -d "$BUILD_CACHE" && ( -f "$BUILD_CACHE/Makefile" || -f "$CONF_MARKER" ) ]]; then
  if [[ $FRESH_BUILD -eq 1 ]]; then
    echo "==> --fresh-build enabled: removing existing build cache at $BUILD_CACHE"
    rm -rf "$BUILD_CACHE"
  elif [[ $NO_PROMPT -eq 0 && -t 0 ]]; then
    read -r -p "Existing build cache found at $BUILD_CACHE. Delete for a fresh build? [y/N]: " _ans
    if [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]; then
      echo "==> Removing build cache at $BUILD_CACHE"
      rm -rf "$BUILD_CACHE"
    else
      echo "==> Reusing existing build cache at $BUILD_CACHE"
    fi
  else
    echo "==> Existing build cache detected at $BUILD_CACHE; reusing."
    echo "    Use --fresh-build to force a clean configure/build."
  fi
fi

# ---------------------------------------------------------------------------
# Configure (once; re-runs automatically if the configure script or the
# chosen configure options change)
# ---------------------------------------------------------------------------
CONF_SRC_HASH="$(printf '%s %s' \
  "$(sha256sum "$VENDOR_SRC/configure" | awk '{print $1}')" \
  "${EXTRA_CONFIGURE_ARGS[*]:-}" | sha256sum | awk '{print $1}')"

reconfigure=0
if [[ ! -f "$CONF_MARKER" ]]; then
  reconfigure=1
elif [[ "$(cat "$CONF_MARKER" 2>/dev/null)" != "$CONF_SRC_HASH" ]]; then
  echo "==> configure script or options changed – reconfiguring"
  reconfigure=1
fi

mkdir -p "$BUILD_CACHE"

if [[ $reconfigure -eq 1 ]]; then
  echo "==> Configuring..."
  cd "$BUILD_CACHE"

  # Binary hardening flags.
  #
  # A plain ./configure does NOT apply the toolchain hardening that Debian's
  # packaged unbound gets from dpkg-buildflags, so a source build would ship a
  # less-hardened binary than the distro package it replaces. We pass the same
  # mitigations explicitly so the source-built unbound is at least as hardened:
  #
  #   -fstack-protector-strong  Stack canaries on functions with stack buffers /
  #                             local arrays / address-taken locals; detects
  #                             stack-smashing overflows at runtime.
  #   -D_FORTIFY_SOURCE=2       Compile-time + runtime bounds checks on common
  #                             libc calls (memcpy, sprintf, ...). Needs -O>=1.
  #   -O2                       Required for _FORTIFY_SOURCE to take effect, and
  #                             matches the project's normal optimization level.
  #   -Wl,-z,relro,-z,now       Full RELRO: map the GOT read-only after startup
  #                             (-z relro) and resolve all symbols eagerly at
  #                             load (-z now), closing GOT-overwrite attacks.
  #                             Without -z now this is only Partial RELRO.
  #
  # PIE is already the Debian/arm64 toolchain default, so it needs no flag here.
  HARDEN_CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
  HARDEN_LDFLAGS="-Wl,-z,relro,-z,now"

  CFLAGS="$HARDEN_CFLAGS" LDFLAGS="$HARDEN_LDFLAGS" "$VENDOR_SRC/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static \
    --with-ssl \
    --with-libexpat=/usr \
    --with-chroot-dir="" \
    --without-pythonmodule \
    --without-dynlibmodule \
    --enable-systemd \
    "${EXTRA_CONFIGURE_ARGS[@]}"
  printf '%s' "$CONF_SRC_HASH" > "$CONF_MARKER"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "==> Building ($(nproc) jobs)..."
cd "$BUILD_CACHE"
make -j"$(nproc)"

# ---------------------------------------------------------------------------
# Stage – install into OUTDIR so the ke-08 layer hook finds the binaries
# ---------------------------------------------------------------------------
echo "==> Staging into $STAGING_DIR ..."
mkdir -p "$STAGING_DIR"
make install DESTDIR="$STAGING_DIR"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
UNBOUND_BIN="$STAGING_DIR/usr/sbin/unbound"
if [[ ! -x "$UNBOUND_BIN" ]]; then
  echo "ERROR: expected binary not found after install: $UNBOUND_BIN" >&2
  exit 1
fi

echo "==> Staged successfully: $UNBOUND_BIN"
echo "    $("$UNBOUND_BIN" -V 2>&1 | head -1)"

if [[ $WITH_PIHOLE_CONF_CHECK -eq 1 ]]; then
  CHECKCONF_BIN="$STAGING_DIR/usr/sbin/unbound-checkconf"
  STAGED_PIHOLE_CONF="$STAGING_DIR/etc/unbound/unbound.conf.d/pi-hole.conf"

  if [[ ! -f "$PIHOLE_CONF_SRC" ]]; then
    echo "ERROR: Pi-hole Unbound config not found: $PIHOLE_CONF_SRC" >&2
    exit 1
  fi

  if [[ ! -x "$CHECKCONF_BIN" ]]; then
    echo "ERROR: expected checker binary not found after install: $CHECKCONF_BIN" >&2
    exit 1
  fi

  install -d -m 0755 "$(dirname "$STAGED_PIHOLE_CONF")"
  cp -a "$PIHOLE_CONF_SRC" "$STAGED_PIHOLE_CONF"

  echo "==> Validating staged Pi-hole config with unbound-checkconf"
  "$CHECKCONF_BIN" "$STAGED_PIHOLE_CONF" >/dev/null
  echo "==> Pi-hole config check passed: $STAGED_PIHOLE_CONF"
fi
