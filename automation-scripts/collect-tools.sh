#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/binaries/tools"
TOOLS_ENV="${ROOT_DIR}/configs/offline-tools.env"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

load_versions() {
  [[ -f "$TOOLS_ENV" ]] || fail "Tools version file not found: $TOOLS_ENV"
  # shellcheck disable=SC1090
  source "$TOOLS_ENV"

  [[ -n "${HELM_VERSION:-}" ]] || fail "HELM_VERSION is missing"
  [[ -n "${KUSTOMIZE_VERSION:-}" ]] || fail "KUSTOMIZE_VERSION is missing"
}

download_helm() {
  local url
  local archive
  local workdir

  url="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  archive="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  workdir="$(mktemp -d)"

  echo "Downloading Helm ${HELM_VERSION}"
  curl -fsSL "$url" -o "${workdir}/${archive}"

  tar -xzf "${workdir}/${archive}" -C "$workdir"
  cp "${workdir}/linux-amd64/helm" "${TOOLS_DIR}/helm"
  chmod +x "${TOOLS_DIR}/helm"

  echo "Helm saved to ${TOOLS_DIR}/helm"
}

download_kustomize() {
  local url
  local archive
  local workdir

  url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
  archive="kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
  workdir="$(mktemp -d)"

  echo "Downloading Kustomize ${KUSTOMIZE_VERSION}"
  curl -fsSL "$url" -o "${workdir}/${archive}"

  tar -xzf "${workdir}/${archive}" -C "$workdir"
  cp "${workdir}/kustomize" "${TOOLS_DIR}/kustomize"
  chmod +x "${TOOLS_DIR}/kustomize"

  echo "Kustomize saved to ${TOOLS_DIR}/kustomize"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: ./automation-scripts/collect-tools.sh"
    echo "Downloads Helm and Kustomize into binaries/tools/"
    exit 0
  fi

  require_command curl
  require_command tar
  require_command cp
  require_command chmod
  require_command mktemp

  mkdir -p "$TOOLS_DIR"
  load_versions

  download_helm
  download_kustomize

  echo "Tools collection finished"
  "${TOOLS_DIR}/helm" version --short
  "${TOOLS_DIR}/kustomize" version
}

main "$@"
