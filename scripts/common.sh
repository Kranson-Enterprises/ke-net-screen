#!/bin/bash

# Shared script helpers for release and validation flows.

info() {
  echo "[info] $1"
}

step() {
  echo ""
  echo "[step] $1"
}

fail() {
  echo "[fail] $1"
  exit 1
}

# Resolve the repository root from a script path, preferring git metadata.
get_repo_root() {
  local script_path="${1:-${BASH_SOURCE[0]}}"
  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"

  if git -C "$script_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$script_dir" rev-parse --show-toplevel
    return 0
  fi

  # Fallback for environments without git metadata.
  cd "$script_dir/.." && pwd
}

# Resolve deploy directory from explicit arg or latest deploy-* output.
resolve_deploy_dir() {
  local root_dir="$1"
  local requested_dir="${2:-}"

  if [[ -n "$requested_dir" ]]; then
    echo "$requested_dir"
    return 0
  fi

  ls -1dt "$root_dir"/ke-net-screen-build/deploy-* 2>/dev/null | head -n1 || true
}