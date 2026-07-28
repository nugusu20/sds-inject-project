# SDS Inject — Offline Kubernetes Installer

![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.30.14-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04%20LTS-E95420?style=flat-square&logo=ubuntu&logoColor=white)
![Docker & containerd](https://img.shields.io/badge/Containerd-v2.2.1-2496ED?style=flat-square&logo=docker&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?style=flat-square&logo=githubactions&logoColor=white)
![Air-Gapped Ready](https://img.shields.io/badge/Environment-Air--Gapped%20%2F%20Offline-success?style=flat-square)

**SDS Inject** builds a self-contained, offline-style single-run installer (`.run`) that bootstraps a complete Kubernetes cluster on Debian-based Linux environments without requiring active internet access during deployment.

It encapsulates binaries, system packages, configuration files, CNI setups, and helper tools into a single executable generated via `makeself`, enforcing zero-trust safety checks and recovery logic.

---

## ✨ Key Features

- **Air-Gapped Design:** Pre-bundles all required Debian packages (`.deb`) and essential tools (`kubectl`, `helm`, `kustomize`).
- **Single Executable Output:** Packages the entire installer into a portable `.run` binary using `makeself`.
- **Strict Guardrails & Safety Policy:** Automatic cluster-state detection prevents accidental overwrites or destruction of active control planes.
- **Dry-Run Mode:** Built-in `--dry-run` flag allows complete pre-execution validation and log checking without modifying the host system.
- **Resilient Recovery Logic:** Includes automated repair flows for incomplete `kubeadm init` executions, super-admin context validation, and RBAC recovery.
- **CI/CD Integrated:** Automated shell syntax testing, artifact validation, and SSH-based automated CD deployments via GitHub Actions.

---

## 📋 Environment & Version Matrix

To eliminate compatibility drift between `kubeadm`, `kubelet`, and container runtimes, all core component versions are strictly pinned:

| Component | Pinned Version | Note |
| :--- | :--- | :--- |
| **Target OS** | Ubuntu Server 22.04.5 LTS | Debian-based baseline |
| **Architecture** | `amd64` | x86_64 architecture |
| **Kubernetes Core** | `v1.30.14` | `kubeadm`, `kubelet`, `kubectl` |
| **Container Runtime** | `containerd` `2.2.1` | Configured with systemd cgroup driver |
| **Helm** | `v3.15.4` | Bundled in `binaries/tools` |
| **Kustomize** | `v5.4.2` | Bundled in `binaries/tools` |
| **Packaging Engine** | `makeself` `2.5.0` | Creates self-extracting archive |
| **Testing Harness** | Vagrant / VirtualBox | Multi-node local validation lab |

---

## 📂 Project Structure

```text
├── automation-scripts/   # Primary installation, recovery, and collection scripts
├── binaries/
│   ├── packages/         # Offline Debian (.deb) dependencies
│   └── tools/            # Pre-compiled helper binaries (kubectl, helm, kustomize)
├── configs/              # Kubeadm manifests, containerd configs, CNI definitions
├── cd/                   # Continuous Deployment SSH-based execution scripts
├── dist/                 # Generated .run installer artifacts
├── docs/screenshots/     # Execution logs and lab validation evidence
└── .github/workflows/    # CI/CD pipeline automation
