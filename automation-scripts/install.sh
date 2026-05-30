#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
ROLE=""
DRY_RUN="false"
LOG_DIR="${SDS_LOG_DIR:-./logs}"
LOG_FILE=""
K8S_NODE_STATE="unknown"

MIN_CPU="2"
MIN_MEMORY_MB="2048"
MIN_DISK_GB="10"
REQUIRED_COMMANDS=("bash" "awk" "grep" "sed" "df" "free" "systemctl" "nproc" "swapon")

usage() {
  cat <<USAGE
Usage:
  sudo ./${SCRIPT_NAME} --role control-plane [--dry-run]
  sudo ./${SCRIPT_NAME} --role worker [--dry-run]
  sudo ./${SCRIPT_NAME} --role both [--dry-run]

Options:
  --role      Required. Allowed values: control-plane, worker, both
  --dry-run   Validate flow without installing anything
  --help      Show this help message
USAGE
}

init_logging() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/sds-inject-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
}

log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  if [[ -n "$LOG_FILE" ]]; then
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
  else
    echo "[$timestamp] [$level] $message"
  fi
}

on_error() {
  local exit_code="$1"
  local line_number="$2"
  local command="$3"

  log "ERROR" "Unexpected failure detected"
  log "ERROR" "Exit code: ${exit_code}"
  log "ERROR" "Line: ${line_number}"
  log "ERROR" "Command: ${command}"
  log "ERROR" "Log file: ${LOG_FILE}"
  log "ERROR" "Suggestion: review the log file and rerun with --dry-run before real installation."
  exit "$exit_code"
}

fail() {
  local message="$1"
  log "ERROR" "$message"
  log "ERROR" "Suggestion: run ./${SCRIPT_NAME} --help and verify the selected role."
  exit 1
}

warn() {
  local message="$1"
  log "WARN" "$message"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        [[ $# -ge 2 ]] || fail "Missing value for --role"
        ROLE="$2"
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

validate_role() {
  case "$ROLE" in
    control-plane|worker|both)
      log "INFO" "Selected role: $ROLE"
      ;;
    "")
      fail "Missing required argument: --role"
      ;;
    *)
      fail "Invalid role: $ROLE"
      ;;
  esac
}

check_required_commands() {
  local missing=()

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "Missing required commands: ${missing[*]}"
  fi

  log "INFO" "Required commands check passed"
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "INFO" "Detected OS: ${PRETTY_NAME:-unknown}"
  else
    fail "Cannot read /etc/os-release"
  fi

  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    fail "Unsupported OS family. Expected Ubuntu/Debian-based system."
  fi

  log "INFO" "OS check passed"
}

check_cpu() {
  local cpu_count
  cpu_count="$(nproc)"

  log "INFO" "Detected CPU cores: ${cpu_count}"

  if (( cpu_count < MIN_CPU )); then
    fail "Not enough CPU cores. Required: ${MIN_CPU}, detected: ${cpu_count}"
  fi

  log "INFO" "CPU check passed"
}

check_memory() {
  local memory_mb
  memory_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"

  log "INFO" "Detected memory: ${memory_mb}MB"

  if (( memory_mb < MIN_MEMORY_MB )); then
    fail "Not enough memory. Required: ${MIN_MEMORY_MB}MB, detected: ${memory_mb}MB"
  fi

  log "INFO" "Memory check passed"
}

check_disk() {
  local disk_available_mb
  local min_disk_mb

  disk_available_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  min_disk_mb=$((MIN_DISK_GB * 1024))

  log "INFO" "Detected available disk on /: ${disk_available_mb}MB"

  if (( disk_available_mb < min_disk_mb )); then
    fail "Not enough disk space on /. Required: ${MIN_DISK_GB}GB, detected: $((disk_available_mb / 1024))GB"
  fi

  log "INFO" "Disk check passed"
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    fail "systemctl not found. systemd is required."
  fi

  if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
    fail "systemd is not PID 1. This installer must run on a systemd-based machine."
  fi

  log "INFO" "systemd check passed"
}

check_swap() {
  if swapon --show | grep -q .; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Swap is active. Real Kubernetes installation will fail until swap is disabled."
    else
      fail "Swap is active. Disable swap before real Kubernetes installation."
    fi
  else
    log "INFO" "Swap check passed: swap is disabled"
  fi
}

detect_kubernetes_node_state() {
  local has_kubeadm="false"
  local has_kubelet="false"
  local has_kubectl="false"
  local has_kubelet_service="false"

  command -v kubeadm >/dev/null 2>&1 && has_kubeadm="true"
  command -v kubelet >/dev/null 2>&1 && has_kubelet="true"
  command -v kubectl >/dev/null 2>&1 && has_kubectl="true"

  if systemctl list-unit-files kubelet.service --no-legend 2>/dev/null | grep -q '^kubelet.service'; then
    has_kubelet_service="true"
  fi

  log "INFO" "Kubernetes detection: kubeadm=${has_kubeadm}, kubelet=${has_kubelet}, kubectl=${has_kubectl}, kubelet_service=${has_kubelet_service}"

  if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    K8S_NODE_STATE="control-plane"
  elif [[ -f /etc/kubernetes/kubelet.conf || "$has_kubelet_service" == "true" || "$has_kubelet" == "true" ]]; then
    K8S_NODE_STATE="worker"
  elif [[ ! -d /etc/kubernetes && "$has_kubeadm" == "false" && "$has_kubelet" == "false" && "$has_kubectl" == "false" && "$has_kubelet_service" == "false" ]]; then
    K8S_NODE_STATE="not-installed"
  else
    K8S_NODE_STATE="unknown"
  fi

  log "INFO" "Detected Kubernetes node state: ${K8S_NODE_STATE}"

  if [[ "$K8S_NODE_STATE" == "unknown" ]]; then
    warn "Kubernetes state is unclear. Real installation should stop until the node is inspected."
  fi
}

preflight_checks() {
  log "INFO" "Running preflight checks"

  check_os
  check_required_commands
  check_cpu
  check_memory
  check_disk
  check_systemd
  check_swap
  detect_kubernetes_node_state

  if [[ "$DRY_RUN" == "false" && "${EUID}" -ne 0 ]]; then
    fail "Root privileges are required. Run with sudo."
  fi

  log "INFO" "Preflight checks passed"
}

run_control_plane_flow() {
  log "INFO" "Control-plane flow selected"
  log "INFO" "Detected Kubernetes state before action: ${K8S_NODE_STATE}"
  log "INFO" "Dry-run mode: no Kubernetes control-plane changes will be made"
}

run_worker_flow() {
  log "INFO" "Worker flow selected"
  log "INFO" "Detected Kubernetes state before action: ${K8S_NODE_STATE}"
  log "INFO" "Dry-run mode: no Kubernetes worker changes will be made"
}

run_install() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Running in dry-run mode"
  else
    fail "Real installation is not enabled in this base script yet"
  fi

  case "$ROLE" in
    control-plane)
      run_control_plane_flow
      ;;
    worker)
      run_worker_flow
      ;;
    both)
      run_control_plane_flow
      run_worker_flow
      ;;
  esac
}

main() {
  init_logging
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

  log "INFO" "Starting SDS Inject installer"
  parse_args "$@"
  validate_role
  preflight_checks
  run_install
  log "INFO" "SDS Inject installer finished successfully"
}

main "$@"
