#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/binaries/packages"
MANIFEST_FILE="${ROOT_DIR}/configs/offline-packages.txt"

usage() {
  cat <<USAGE
Usage:
  ./automation-scripts/collect-packages.sh

Purpose:
  Download required .deb packages into binaries/packages/.

Notes:
  This script uses the apt repositories configured on the build machine.
  Kubernetes packages require a Kubernetes apt repository to be configured first.
USAGE
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_command apt-get
  require_command apt-cache
  require_command mkdir

  [[ -f "$MANIFEST_FILE" ]] || fail "Manifest not found: $MANIFEST_FILE"

  mkdir -p "$PACKAGE_DIR"

  echo "Package directory: $PACKAGE_DIR"
  echo "Manifest file: $MANIFEST_FILE"

  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

    echo "Checking package: $package"

    if ! apt-cache show "$package" >/dev/null 2>&1; then
      fail "Package not available in configured apt repositories: $package"
    fi

    echo "Downloading package: $package"
    (
      cd "$PACKAGE_DIR"
      apt-get download "$package"
    )
  done < "$MANIFEST_FILE"

  echo "Package collection finished"
  find "$PACKAGE_DIR" -maxdepth 1 -type f -name "*.deb" -printf "%f\n" | sort
}

main "$@"
