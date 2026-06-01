#!/bin/bash
# update-submodules-to-main-or-master.sh
# This script checks out 'main' or 'master' in each submodule, pulls the latest, and reports status.

set -e

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

echo "Updating all submodules to 'main' or 'master'..."

git submodule foreach --quiet '
  echo "\n==> Processing $name in $path"
  branch=""
  git fetch origin
  if git show-ref --verify --quiet refs/remotes/origin/main; then
    branch="main"
  elif git show-ref --verify --quiet refs/remotes/origin/master; then
    branch="master"
  else
    echo "  No main or master branch found in $name. Skipping."
    exit 0
  fi
  git checkout "$branch"
  git pull origin "$branch"
  git status -sb
'

echo "\nAll submodules processed."
