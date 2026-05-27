# SDS Inject

Single-file Kubernetes installer project.

## Goal

Build one self-running installer file that can install Kubernetes components and helper tools.

## Target OS

Ubuntu Server 22.04 LTS / Debian-based systems.

## Project Structure

```text
automation-scripts/  Core install scripts
binaries/            Kubernetes and tool binaries
cd/                  Deployment scripts
ci/                  CI validation and packaging
configs/             Configuration templates
logs/                Runtime logs, ignored by Git
build-script         Installer build wrapper
