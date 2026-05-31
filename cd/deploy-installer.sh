#!/usr/bin/env bash
set -Eeuo pipefail

TARGET=""
PORT="22"
IDENTITY_FILE=""
INSTALLER="dist/sds-inject-installer.run"
DRY_RUN="false"
APISERVER_ADVERTISE_ADDRESS="${SDS_APISERVER_ADVERTISE_ADDRESS:-}"
POD_CIDR="${SDS_POD_CIDR:-10.244.0.0/16}"
REMOTE_DIR="${SDS_REMOTE_DIR:-/tmp/sds-inject}"
REMOTE_INSTALLER="${REMOTE_DIR}/sds-inject-installer.run"

usage() {
  cat <<USAGE
Usage:
  $0 --target user@host [options]

Options:
  --target user@host
  --port PORT
  --identity-file PATH
  --installer PATH
  --apiserver-advertise-address IP
  --pod-cidr CIDR
  --dry-run
  -h, --help
USAGE
}

log() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

fail() {
  log "ERROR" "$1"
  exit 1
}

on_error() {
  local exit_code=$?
  log "ERROR" "CD deployment failed at line ${BASH_LINENO[0]} with exit code ${exit_code}"
  exit "$exit_code"
}

trap on_error ERR

shell_quote() {
  printf "%q" "$1"
}

extract_host_from_target() {
  local value="${TARGET#*@}"
  value="${value%%:*}"
  printf '%s' "$value"
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --identity-file)
      IDENTITY_FILE="${2:-}"
      shift 2
      ;;
    --installer)
      INSTALLER="${2:-}"
      shift 2
      ;;
    --apiserver-advertise-address)
      APISERVER_ADVERTISE_ADDRESS="${2:-}"
      shift 2
      ;;
    --pod-cidr)
      POD_CIDR="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$TARGET" ]] || fail "--target is required"
[[ -f "$INSTALLER" ]] || fail "Installer not found: $INSTALLER"

command -v ssh >/dev/null 2>&1 || fail "ssh is required"
command -v scp >/dev/null 2>&1 || fail "scp is required"

if [[ -n "$IDENTITY_FILE" && ! -f "$IDENTITY_FILE" ]]; then
  fail "Identity file not found: $IDENTITY_FILE"
fi

if [[ -z "$APISERVER_ADVERTISE_ADDRESS" ]]; then
  TARGET_HOST="$(extract_host_from_target)"
  if is_ipv4 "$TARGET_HOST"; then
    APISERVER_ADVERTISE_ADDRESS="$TARGET_HOST"
  fi
fi

SSH_OPTS=(
  -p "$PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
)

SCP_OPTS=(
  -P "$PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
)

if [[ -n "$IDENTITY_FILE" ]]; then
  SSH_OPTS+=(-i "$IDENTITY_FILE")
  SCP_OPTS+=(-i "$IDENTITY_FILE")
fi

run_ssh() {
  local command="$1"
  ssh "${SSH_OPTS[@]}" "$TARGET" "bash -lc $(shell_quote "$command")"
}

detect_remote_kubernetes_state() {
  run_ssh '
if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  echo control-plane
elif [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo worker
elif [[ -d /etc/kubernetes && -n "$(find /etc/kubernetes -mindepth 1 -maxdepth 2 -print -quit 2>/dev/null)" ]]; then
  echo unknown
else
  echo not-installed
fi
'
}

log "INFO" "Starting SDS Inject CD deployment"
log "INFO" "Target: ${TARGET}"

REMOTE_STATE="$(detect_remote_kubernetes_state)"
log "INFO" "Detected remote Kubernetes state: ${REMOTE_STATE}"

INSTALL_ROLE=""

case "$REMOTE_STATE" in
  not-installed)
    INSTALL_ROLE="control-plane"
    [[ -n "$APISERVER_ADVERTISE_ADDRESS" ]] || fail "Control-plane install requires --apiserver-advertise-address"
    log "INFO" "Kubernetes is not installed. CD will install control-plane only."
    log "INFO" "API server advertise address: ${APISERVER_ADVERTISE_ADDRESS}"
    log "INFO" "Pod CIDR: ${POD_CIDR}"
    ;;
  worker)
    INSTALL_ROLE="worker"
    log "INFO" "Worker node detected. CD will reinstall or upgrade worker role only."
    ;;
  control-plane)
    fail "Control-plane already exists. CD refuses to reinstall control-plane automatically."
    ;;
  *)
    fail "Unknown Kubernetes state. CD refuses to continue."
    ;;
esac

if [[ "$DRY_RUN" == "true" ]]; then
  log "INFO" "Dry-run mode: no files will be copied and no installer will run"
  log "INFO" "Planned installer role: ${INSTALL_ROLE}"
  log "INFO" "CD deployment finished successfully"
  exit 0
fi

log "INFO" "Creating remote directory: ${REMOTE_DIR}"
run_ssh "mkdir -p $(shell_quote "$REMOTE_DIR")"

log "INFO" "Copying installer to remote target"
scp "${SCP_OPTS[@]}" "$INSTALLER" "${TARGET}:${REMOTE_INSTALLER}"

log "INFO" "Making remote installer executable"
run_ssh "chmod +x $(shell_quote "$REMOTE_INSTALLER")"

if [[ "$INSTALL_ROLE" == "control-plane" ]]; then
  run_ssh "sudo env SDS_APISERVER_ADVERTISE_ADDRESS=$(shell_quote "$APISERVER_ADVERTISE_ADDRESS") SDS_POD_CIDR=$(shell_quote "$POD_CIDR") $(shell_quote "$REMOTE_INSTALLER") -- --role control-plane"
else
  run_ssh "sudo $(shell_quote "$REMOTE_INSTALLER") -- --role worker"
fi

log "INFO" "CD deployment finished successfully"
