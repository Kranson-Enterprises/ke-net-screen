#!/bin/bash
# Verify that source-built Unbound artifacts are present and current in the
# rpi-image-gen filesystem produced by ke-net-screen.sh --source-unbound.
#
# Usage:
#   scripts/check-unbound-build.sh [OUTDIR]
#
# OUTDIR defaults to ke-net-screen-build/ in the project root.
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTDIR="${1:-$PROJECT_ROOT/ke-net-screen-build}"

PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ok()   { printf '  [PASS] %s\n' "$*"; (( PASS++ )); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; (( FAIL++ )); }
warn() { printf '  [WARN] %s\n' "$*"; (( WARN++ )); }
hdr()  { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Locate key directories
# ---------------------------------------------------------------------------
hdr "Locating build directories"

GNU_TYPE="$(dpkg-architecture -qDEB_HOST_GNU_TYPE 2>/dev/null || echo "aarch64-linux-gnu")"
STAGING_USR="$OUTDIR/build/staging/$GNU_TYPE/usr"
BUILD_CACHE="$PROJECT_ROOT/.unbound-build"

# Find the most recently modified chroot-*/filesystem under OUTDIR
ROOTFS="$(find "$OUTDIR" -maxdepth 2 -type d -name filesystem 2>/dev/null \
          | sort -t/ -k1,1 | tail -1)"

if [[ -z "$ROOTFS" ]]; then
  fail "No chroot filesystem found under $OUTDIR"
  echo ""; echo "RESULT: 0 passed, $FAIL failed, $WARN warnings — cannot continue"
  exit 1
fi
ok "Rootfs at $ROOTFS"

if [[ ! -d "$STAGING_USR" ]]; then
  fail "Staging usr not found: $STAGING_USR"
  fail "Run: ./ke-net-screen.sh --source-unbound --build-only"
  echo ""; echo "RESULT: 0 passed, $FAIL failed, $WARN warnings — cannot continue"
  exit 1
fi
ok "Staging usr at $STAGING_USR"

# ---------------------------------------------------------------------------
# 2. Expected binaries in rootfs usr/sbin
# ---------------------------------------------------------------------------
hdr "Checking rootfs binaries (usr/sbin)"

SBIN_EXPECTED=(
  unbound
  unbound-anchor
  unbound-checkconf
  unbound-control
  unbound-control-setup
  unbound-host
)

for bin in "${SBIN_EXPECTED[@]}"; do
  rootfs_bin="$ROOTFS/usr/sbin/$bin"
  staging_bin="$STAGING_USR/sbin/$bin"

  if [[ ! -e "$rootfs_bin" ]]; then
    fail "Missing in rootfs: usr/sbin/$bin"
    continue
  fi

  # Check it's not a directory
  if [[ -d "$rootfs_bin" ]]; then
    fail "Expected file but found directory: usr/sbin/$bin"
    continue
  fi

  ok "Present: usr/sbin/$bin"

  # Compare against staging source if available
  if [[ -e "$staging_bin" ]]; then
    staging_size=$(stat -c '%s' "$staging_bin")
    rootfs_size=$(stat -c '%s' "$rootfs_bin")
    if [[ "$staging_size" -eq "$rootfs_size" ]]; then
      ok "  Size matches staging ($staging_size bytes)"
    else
      warn "  Size mismatch: rootfs=$rootfs_size staging=$staging_size — $bin"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 3. Shared library in rootfs usr/lib
# ---------------------------------------------------------------------------
hdr "Checking rootfs shared library (usr/lib)"

# Find versioned .so
VERSIONED_SO="$(find "$ROOTFS/usr/lib" -maxdepth 1 -name 'libunbound.so.*.*' 2>/dev/null | sort | tail -1)"
if [[ -z "$VERSIONED_SO" ]]; then
  fail "No versioned libunbound.so.*.* found in rootfs usr/lib"
else
  so_name="$(basename "$VERSIONED_SO")"
  ok "Versioned library: usr/lib/$so_name"

  # Check soname symlink (libunbound.so.8 → versioned)
  SONAME_LINK="$ROOTFS/usr/lib/libunbound.so.8"
  if [[ -L "$SONAME_LINK" ]]; then
    ok "Soname symlink present: usr/lib/libunbound.so.8 -> $(readlink "$SONAME_LINK")"
  else
    warn "Soname symlink missing: usr/lib/libunbound.so.8 (ldconfig may create it on first boot)"
  fi

  # Compare versioned SO against staging
  STAGING_SO="$(find "$STAGING_USR/lib" -maxdepth 1 -name 'libunbound.so.*.*' 2>/dev/null | sort | tail -1)"
  if [[ -n "$STAGING_SO" ]]; then
    staging_so_name="$(basename "$STAGING_SO")"
    if [[ "$so_name" == "$staging_so_name" ]]; then
      ok "Library version matches staging: $so_name"
    else
      fail "Version mismatch: rootfs has $so_name, staging has $staging_so_name"
    fi

    staging_size=$(stat -c '%s' "$STAGING_SO")
    rootfs_size=$(stat -c '%s' "$VERSIONED_SO")
    if [[ "$staging_size" -eq "$rootfs_size" ]]; then
      ok "Library size matches staging ($staging_size bytes)"
    else
      warn "Library size mismatch: rootfs=$rootfs_size staging=$staging_size"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Version string from the binary
# ---------------------------------------------------------------------------
hdr "Unbound version in rootfs binary"

ROOTFS_UB="$ROOTFS/usr/sbin/unbound"
if [[ -x "$ROOTFS_UB" ]]; then
  VER_STRING="$(strings "$ROOTFS_UB" 2>/dev/null \
    | grep -E '^Version [0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ -n "$VER_STRING" ]]; then
    ok "Version string in rootfs binary: $VER_STRING"
  else
    # Fallback: look for the version pattern anywhere
    VER_STRING="$(strings "$ROOTFS_UB" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ -n "$VER_STRING" ]] && ok "Version found in binary: $VER_STRING" \
                             || warn "Could not extract version from binary"
  fi
fi

# Also check the source build cache for the version it was built from
if [[ -f "$BUILD_CACHE/config.h" ]]; then
  BUILT_VER="$(grep 'PACKAGE_VERSION' "$BUILD_CACHE/config.h" \
    | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"' | head -1)"
  if [[ -n "$BUILT_VER" ]]; then
    ok "Source cache built version: $BUILT_VER"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Confirm source-built binary differs from Debian package version
# ---------------------------------------------------------------------------
hdr "Verifying source-built binary is installed (not Debian package default)"

DEB_UB_VERSION="$(dpkg-query -W -f='${Version}' unbound 2>/dev/null || echo "not-installed")"
if [[ "$DEB_UB_VERSION" != "not-installed" ]]; then
  # Extract just the upstream part (strip epoch/revision)
  DEB_UPSTREAM="$(echo "$DEB_UB_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$VER_STRING" && "$VER_STRING" != *"$DEB_UPSTREAM"* ]]; then
    ok "Rootfs binary version ($VER_STRING) differs from host deb version ($DEB_UPSTREAM)"
  else
    warn "Cannot confirm source vs package distinction (host deb=$DEB_UPSTREAM, rootfs=$VER_STRING)"
  fi
else
  ok "Unbound not installed on build host — no version ambiguity"
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
printf '\n'
printf '=%.0s' {1..60}
printf '\nRESULT: %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
printf '=%.0s' {1..60}
printf '\n'

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
