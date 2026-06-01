#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
ROLE=""
DRY_RUN="false"
LOG_DIR=""
LOG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${SDS_PACKAGE_DIR:-${PAYLOAD_ROOT}/binaries/packages}"
TOOLS_DIR="${SDS_TOOLS_DIR:-${PAYLOAD_ROOT}/binaries/tools}"
OFFLINE_PACKAGES_MANIFEST="${SDS_OFFLINE_PACKAGES_MANIFEST:-${PAYLOAD_ROOT}/configs/offline-packages.txt}"
KUBEADM_POD_CIDR="${SDS_POD_CIDR:-10.244.0.0/16}"
APISERVER_ADVERTISE_ADDRESS="${SDS_APISERVER_ADVERTISE_ADDRESS:-}"
K8S_NODE_STATE="unknown"

MIN_CPU="2"
MIN_MEMORY_MB="2048"
MIN_DISK_GB="10"
REQUIRED_COMMANDS=("bash" "awk" "grep" "sed" "df" "free" "systemctl" "nproc" "swapon" "find" "install")

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

resolve_log_dir() {
  if [[ -n "${SDS_LOG_DIR:-}" ]]; then
    LOG_DIR="$SDS_LOG_DIR"
  elif [[ "${EUID}" -eq 0 ]]; then
    LOG_DIR="/var/log/sds-inject"
  else
    LOG_DIR="./logs"
  fi
}

init_logging() {
  resolve_log_dir
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

check_offline_packages() {
  log "INFO" "Checking offline packages manifest: ${OFFLINE_PACKAGES_MANIFEST}"
  log "INFO" "Checking offline packages directory: ${PACKAGE_DIR}"

  if [[ ! -f "$OFFLINE_PACKAGES_MANIFEST" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Offline packages manifest not found: ${OFFLINE_PACKAGES_MANIFEST}"
      return 0
    fi
    fail "Offline packages manifest not found: ${OFFLINE_PACKAGES_MANIFEST}"
  fi

  if [[ ! -d "$PACKAGE_DIR" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Offline packages directory not found: ${PACKAGE_DIR}"
      return 0
    fi
    fail "Offline packages directory not found: ${PACKAGE_DIR}"
  fi

  local missing=()
  local package
  local found

  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

    found="false"

    if compgen -G "${PACKAGE_DIR}/${package}"'*.deb' >/dev/null; then
      found="true"
    fi

    if [[ "$found" == "false" ]]; then
      missing+=("$package")
    fi
  done < "$OFFLINE_PACKAGES_MANIFEST"

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Missing offline .deb packages: ${missing[*]}"
      return 0
    fi
    fail "Missing offline .deb packages: ${missing[*]}"
  fi

  log "INFO" "Offline packages check passed"
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
  elif [[ -f /etc/kubernetes/kubelet.conf ]]; then
    K8S_NODE_STATE="worker"
  elif [[ ! -f /etc/kubernetes/admin.conf && ! -f /etc/kubernetes/kubelet.conf && ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    K8S_NODE_STATE="not-installed"
  else
    K8S_NODE_STATE="unknown"
  fi

  log "INFO" "Detected Kubernetes node state: ${K8S_NODE_STATE}"

  if [[ "$K8S_NODE_STATE" == "unknown" ]]; then
    warn "Kubernetes state is unclear. Real installation should stop until the node is inspected."
  fi
}

enforce_installer_safety_policy() {
  log "INFO" "Evaluating installer safety policy: role=${ROLE}, node_state=${K8S_NODE_STATE}, dry_run=${DRY_RUN}"

  case "$K8S_NODE_STATE" in
    not-installed)
      if [[ "$ROLE" == "worker" ]]; then
        warn "Kubernetes is not installed. Worker install requires join configuration. CD should install control-plane only on an empty node."
      elif [[ "$ROLE" == "both" ]]; then
        warn "Role both was explicitly selected on a clean node."
      fi
      log "INFO" "Safety policy passed for clean node"
      ;;
    worker)
      if [[ "$ROLE" == "worker" ]]; then
        log "INFO" "Existing worker node detected. Worker reinstall/upgrade path is allowed."
      elif [[ "$DRY_RUN" == "true" ]]; then
        warn "Existing worker node detected. Real installation would refuse role: ${ROLE}"
      else
        fail "Existing worker node detected. Refusing role '${ROLE}'. Only worker reinstall/upgrade is allowed."
      fi
      ;;
    control-plane)
      if [[ "$DRY_RUN" == "true" ]]; then
        warn "Existing control-plane detected. Real installation would be refused."
      else
        fail "Existing control-plane detected. Refusing automatic reinstall/upgrade on control-plane."
      fi
      ;;
    unknown)
      if [[ "$DRY_RUN" == "true" ]]; then
        warn "Kubernetes node state is unknown. Real installation would be refused."
      else
        fail "Kubernetes node state is unknown. Refusing real installation."
      fi
      ;;
    *)
      fail "Invalid internal Kubernetes node state: ${K8S_NODE_STATE}"
      ;;
  esac
}

check_offline_tools() {
  log "INFO" "Checking offline tools directory: ${TOOLS_DIR}"

  local missing=()

  for tool in helm kustomize; do
    if [[ ! -x "${TOOLS_DIR}/${tool}" ]]; then
      missing+=("$tool")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Missing offline tools: ${missing[*]}"
      return 0
    fi

    fail "Missing offline tools: ${missing[*]}"
  fi

  log "INFO" "Offline tools check passed"
}

install_offline_tools() {
  log "INFO" "Preparing offline tools installation"

  check_offline_tools

  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Dry-run mode: offline tools will not be installed"
    return 0
  fi

  install -m 0755 "${TOOLS_DIR}/helm" /usr/local/bin/helm
  install -m 0755 "${TOOLS_DIR}/kustomize" /usr/local/bin/kustomize

  log "INFO" "Offline tools installed to /usr/local/bin"
}

collect_offline_deb_packages() {
  local package
  local matches=()
  OFFLINE_DEB_FILES=()

  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

    matches=()
    while IFS= read -r match; do
      matches+=("$match")
    done < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name "${package}*.deb" | sort)

    if [[ "${#matches[@]}" -gt 0 ]]; then
      OFFLINE_DEB_FILES+=("${matches[@]}")
    fi
  done < "$OFFLINE_PACKAGES_MANIFEST"
}

install_offline_deb_packages() {
  log "INFO" "Preparing offline .deb package installation"

  collect_offline_deb_packages

  if [[ "${#OFFLINE_DEB_FILES[@]}" -eq 0 ]]; then
    fail "No offline .deb packages found in ${PACKAGE_DIR}"
  fi

  log "INFO" "Offline .deb packages selected: ${#OFFLINE_DEB_FILES[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Dry-run mode: dpkg -i will not be executed"
    return 0
  fi

  log "INFO" "Installing offline .deb packages with dpkg"
  dpkg -i "${OFFLINE_DEB_FILES[@]}" || fail "dpkg installation failed. Add all missing dependency .deb files to binaries/packages."

  log "INFO" "Offline .deb package installation completed"
}

verify_kubernetes_binaries() {
  local missing=()
  local cmd

  for cmd in kubeadm kubelet kubectl containerd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "Kubernetes/runtime commands are not installed yet: ${missing[*]}"
      return 0
    fi

    fail "Required Kubernetes/runtime commands missing after package installation: ${missing[*]}"
  fi

  log "INFO" "Kubernetes/runtime binary verification passed"
}

preflight_checks() {
  log "INFO" "Running preflight checks"

  check_os
  check_required_commands
  check_offline_packages
  check_offline_tools
  check_cpu
  check_memory
  check_disk
  check_systemd
  check_swap
  detect_kubernetes_node_state
  enforce_installer_safety_policy

  if [[ "$DRY_RUN" == "false" && "${EUID}" -ne 0 ]]; then
    fail "Root privileges are required. Run with sudo."
  fi

  log "INFO" "Preflight checks passed"
}

configure_kernel_for_kubernetes() {
  log "INFO" "Configuring kernel modules and sysctl for Kubernetes"

  command -v modprobe >/dev/null 2>&1 || fail "modprobe is required for Kubernetes kernel module configuration"
  command -v sysctl >/dev/null 2>&1 || fail "sysctl is required for Kubernetes network configuration"

  modprobe overlay
  modprobe br_netfilter

  cat > /etc/modules-load.d/sds-kubernetes.conf <<'MODULES'
overlay
br_netfilter
MODULES

  cat > /etc/sysctl.d/sds-kubernetes.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL

  sysctl --system >/dev/null

  log "INFO" "Kernel and sysctl configuration completed"
}

configure_containerd_for_kubernetes() {
  log "INFO" "Configuring containerd for Kubernetes"

  mkdir -p /etc/containerd

  if [[ ! -f /etc/containerd/config.toml ]]; then
    containerd config default > /etc/containerd/config.toml
  fi

  if grep -q "SystemdCgroup = false" /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  elif ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    warn "Could not find SystemdCgroup setting in containerd config. kubeadm may require manual validation."
  fi

  systemctl enable containerd >/dev/null
  systemctl restart containerd

  log "INFO" "containerd configuration completed"
}

write_kubeconfig_for_root() {
  log "INFO" "Writing kubeconfig for root"

  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

    if [[ -n "$sudo_home" && -d "$sudo_home" ]]; then
      mkdir -p "${sudo_home}/.kube"
      cp -f /etc/kubernetes/admin.conf "${sudo_home}/.kube/config"
      chown "${SUDO_USER}:${SUDO_USER}" "${sudo_home}/.kube/config"
      log "INFO" "Kubeconfig written for user: ${SUDO_USER}"
    fi
  fi
}

repair_kubeadm_post_init_resources() {
  log "INFO" "Repairing kubeadm post-init resources"

  local kube_version
  kube_version="$(kubeadm version -o short)"

  cat > /tmp/sds-kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${kube_version}
controlPlaneEndpoint: ${APISERVER_ADVERTISE_ADDRESS}:6443
networking:
  podSubnet: ${KUBEADM_POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

  kubeadm init phase upload-config all \
    --config /tmp/sds-kubeadm-config.yaml \
    --kubeconfig /etc/kubernetes/admin.conf || warn "kubeadm upload-config phase did not complete cleanly"

  kubeadm init phase bootstrap-token \
    --config /tmp/sds-kubeadm-config.yaml \
    --kubeconfig /etc/kubernetes/admin.conf || warn "kubeadm bootstrap-token phase did not complete cleanly"

  kubeadm init phase addon kube-proxy \
    --config /tmp/sds-kubeadm-config.yaml \
    --kubeconfig /etc/kubernetes/admin.conf || warn "kube-proxy addon phase did not complete cleanly"

  kubeadm init phase addon coredns \
    --config /tmp/sds-kubeadm-config.yaml \
    --kubeconfig /etc/kubernetes/admin.conf || warn "coredns addon phase did not complete cleanly"

  kubeadm init phase mark-control-plane \
    --node-name "$(hostname)" \
    --kubeconfig /etc/kubernetes/admin.conf || warn "mark-control-plane phase did not complete cleanly"

  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system create role sds-kubeadm-bootstrap-config-reader \
    --verb=get \
    --resource=configmaps \
    --resource-name=kubeadm-config \
    --dry-run=client -o yaml | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -

  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system create rolebinding sds-kubeadm-bootstrap-config-reader \
    --role=sds-kubeadm-bootstrap-config-reader \
    --group=system:bootstrappers:kubeadm:default-node-token \
    --dry-run=client -o yaml | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -

  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get configmap kubeadm-config kubelet-config >/dev/null

  log "INFO" "kubeadm post-init resources are ready"
}

initialize_control_plane() {
  log "INFO" "Initializing Kubernetes control-plane with kubeadm"

  if [[ -z "$APISERVER_ADVERTISE_ADDRESS" ]]; then
    fail "SDS_APISERVER_ADVERTISE_ADDRESS is required for real control-plane installation"
  fi

  set +e
  kubeadm init \
    --apiserver-advertise-address "$APISERVER_ADVERTISE_ADDRESS" \
    --pod-network-cidr "$KUBEADM_POD_CIDR" \
    --cri-socket unix:///run/containerd/containerd.sock
  local kubeadm_exit=$?
  set -e

  if [[ "$kubeadm_exit" -ne 0 ]]; then
    if [[ -f /etc/kubernetes/admin.conf && -f /etc/kubernetes/super-admin.conf && -f /etc/kubernetes/kubelet.conf ]]; then
      warn "kubeadm init returned non-zero, but Kubernetes bootstrap files exist. Continuing with post-init repair."
    else
      fail "kubeadm init failed before creating required Kubernetes bootstrap files"
    fi
  fi

  apply_admin_rbac_binding
  repair_kubeadm_post_init_resources
  write_kubeconfig_for_root
  configure_basic_cni
  wait_for_node_ready
  print_join_command

  log "INFO" "Kubernetes control-plane initialized successfully"
}

run_control_plane_flow() {
  log "INFO" "Control-plane flow selected"
  log "INFO" "Detected Kubernetes state before action: ${K8S_NODE_STATE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Dry-run mode: no Kubernetes control-plane changes will be made"
    log "INFO" "Dry-run control-plane plan: configure kernel, configure containerd, run kubeadm init"
    return 0
  fi

  configure_kernel_for_kubernetes
  configure_containerd_for_kubernetes
  initialize_control_plane
}

configure_basic_cni() {
  log "INFO" "Writing basic CNI bridge configuration"

  mkdir -p /etc/cni/net.d

  cat > /etc/cni/net.d/10-sds-bridge.conflist <<CNI
{
  "cniVersion": "0.4.0",
  "name": "sds-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "sds-cni0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "${KUBEADM_POD_CIDR}",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "loopback"
    }
  ]
}
CNI

  systemctl restart kubelet || true

  log "INFO" "Basic CNI configuration completed"
}

run_kubeadm_join() {
  [[ -n "${SDS_KUBEADM_JOIN_COMMAND:-}" ]] || fail "SDS_KUBEADM_JOIN_COMMAND is required for real worker installation"

  local join_command="$SDS_KUBEADM_JOIN_COMMAND"

  if [[ "$join_command" != *"--cri-socket"* && "$join_command" != *"--config"* ]]; then
    join_command="${join_command} --cri-socket unix:///run/containerd/containerd.sock"
  fi

  log "INFO" "Running kubeadm join for worker node"
  log "INFO" "Join command received. Token is not printed for safety."

  bash -lc "$join_command"

  log "INFO" "Worker joined the cluster successfully"
}

run_worker_flow() {
  log "INFO" "Worker flow selected"
  log "INFO" "Detected Kubernetes state before action: ${K8S_NODE_STATE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Dry-run mode: no Kubernetes worker changes will be made"
    log "INFO" "Dry-run worker plan: configure kernel, configure containerd, configure CNI, run kubeadm join"
    log "INFO" "Real worker installation requires SDS_KUBEADM_JOIN_COMMAND"
    return 0
  fi

  configure_kernel_for_kubernetes
  configure_containerd_for_kubernetes
  configure_basic_cni
  run_kubeadm_join
}

run_install() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Running in dry-run mode"
    verify_kubernetes_binaries
  else
    log "INFO" "Running in real installation mode"
    install_offline_deb_packages
    install_offline_tools
    verify_kubernetes_binaries
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
