#!/usr/bin/env bash
set -Eeuo pipefail

TARGET=""
SSH_PORT="22"
INSTALLER_PATH="dist/sds-inject-installer.run"
REMOTE_DIR="/tmp/sds-inject"
REMOTE_INSTALLER="${REMOTE_DIR}/sds-inject-installer.run"
DRY_RUN="false"
IDENTITY_FILE=""

usage() {
  cat <<USAGE
Usage:
  ./cd/deploy-installer.sh --target user@host [--port 22] [--identity-file path] [--installer dist/sds-inject-installer.run] [--dry-run]

Options:
  --target     Required. SSH target, example: ubuntu@192.168.56.120
  --port       SSH port. Default: 22
  --identity-file  SSH private key path
  --installer       Path to local installer. Default: dist/sds-inject-installer.run
  --dry-run    Run installer in dry-run mode
  --help       Show help
USAGE
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || fail "Missing value for --target"
        TARGET="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || fail "Missing value for --port"
        SSH_PORT="$2"
        shift 2
        ;;
      --identity-file)
        [[ $# -ge 2 ]] || fail "Missing value for --identity-file"
        IDENTITY_FILE="$2"
        shift 2
        ;;
      --installer)
        [[ $# -ge 2 ]] || fail "Missing value for --installer"
        INSTALLER_PATH="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

detect_remote_kubernetes_state() {
  ssh -p "$SSH_PORT" "$TARGET" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

has_kubeadm="false"
has_kubelet="false"
has_kubectl="false"
has_kubelet_service="false"

command -v kubeadm >/dev/null 2>&1 && has_kubeadm="true"
command -v kubelet >/dev/null 2>&1 && has_kubelet="true"
command -v kubectl >/dev/null 2>&1 && has_kubectl="true"

if systemctl list-unit-files kubelet.service --no-legend 2>/dev/null | grep -q "^kubelet.service"; then
  has_kubelet_service="true"
fi

if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  echo "control-plane"
elif [[ -f /etc/kubernetes/kubelet.conf || "$has_kubelet_service" == "true" || "$has_kubelet" == "true" ]]; then
  echo "worker"
elif [[ ! -d /etc/kubernetes && "$has_kubeadm" == "false" && "$has_kubelet" == "false" && "$has_kubectl" == "false" && "$has_kubelet_service" == "false" ]]; then
  echo "not-installed"
else
  echo "unknown"
fi
REMOTE
}

main() {
  parse_args "$@"

  [[ -n "$TARGET" ]] || fail "--target is required"
  [[ -f "$INSTALLER_PATH" ]] || fail "Installer not found: $INSTALLER_PATH"

  require_command ssh
  require_command scp

  echo "Connecting to target: ${TARGET}"
  node_state="$(detect_remote_kubernetes_state)"
  echo "Detected remote Kubernetes state: ${node_state}"

  case "$node_state" in
    not-installed)
      role="control-plane"
      echo "Kubernetes is not installed. CD will install control-plane only."
      ;;
    worker)
      role="worker"
      echo "Worker node detected. CD allows worker reinstall/upgrade."
      ;;
    control-plane)
      fail "Control-plane detected. CD refuses automatic reinstall/upgrade."
      ;;
    unknown)
      fail "Unknown Kubernetes state. CD refuses deployment."
      ;;
    *)
      fail "Invalid node state: ${node_state}"
      ;;
  esac

  ssh_base "$TARGET" "mkdir -p '$REMOTE_DIR'"
  scp_base "$INSTALLER_PATH" "${TARGET}:${REMOTE_INSTALLER}"
  ssh_base "$TARGET" "chmod +x '$REMOTE_INSTALLER'"

  installer_args=(--role "$role")
  if [[ "$DRY_RUN" == "true" ]]; then
    installer_args+=(--dry-run)
  fi

  echo "Running remote installer with role: ${role}"
  ssh_base "$TARGET" "sudo '$REMOTE_INSTALLER' -- ${installer_args[*]}"

  echo "CD deployment finished successfully"
}

main "$@"
