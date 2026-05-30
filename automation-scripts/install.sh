#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
ROLE=""
DRY_RUN="false"
LOG_DIR="${SDS_LOG_DIR:-./logs}"
LOG_FILE=""

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

preflight_checks() {
  log "INFO" "Running preflight checks"

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "INFO" "Detected OS: ${PRETTY_NAME:-unknown}"
  else
    fail "Cannot read /etc/os-release"
  fi

  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    fail "Unsupported OS family. Expected Ubuntu/Debian-based system."
  fi

  if [[ "$DRY_RUN" == "false" && "${EUID}" -ne 0 ]]; then
    fail "Root privileges are required. Run with sudo."
  fi

  log "INFO" "Preflight checks passed"
}

run_control_plane_flow() {
  log "INFO" "Control-plane flow selected"
  log "INFO" "Dry-run mode: no Kubernetes control-plane changes will be made"
}

run_worker_flow() {
  log "INFO" "Worker flow selected"
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
