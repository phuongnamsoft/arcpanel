#!/usr/bin/env bash
#
# One-time development prerequisites for Arcpanel on Ubuntu WSL2 (e.g. 24.04).
# See docs/project-docs/development-local-setup-wsl2.md
#
# Usage (from repo or any directory):
#   bash scripts/wsl2-install-prerequisites.sh
#
# Non-interactive Rust install (optional):
#   RUSTUP_INIT_SKIP_PATH_CHECK=yes bash scripts/wsl2-install-prerequisites.sh
#
set -euo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.1}"
NODE_VERSION="${NODE_VERSION:-20}"

log() { printf '%s\n' "$*"; }
die() { log "Error: $*" >&2; exit 1; }

if ! command -v sudo &>/dev/null; then
  die "sudo is required (install it or run as root on a minimal image)"
fi

if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  log "Detected OS: ${NAME:-unknown} ${VERSION_ID:-}"
fi

log "Installing apt packages (build tools, git, SSL, Postgres client dev, uuid)..."
sudo apt-get update -y
sudo apt-get install -y \
  build-essential \
  cmake \
  pkg-config \
  libssl-dev \
  libpq-dev \
  git \
  curl \
  ca-certificates \
  uuid-runtime \
  openssl

if ! command -v docker &>/dev/null; then
  log ""
  log "Docker CLI not found. Install Docker Desktop on Windows, enable WSL2 integration for this distro, then re-run this script."
  log "  https://docs.docker.com/desktop/wsl/"
  die "docker is required for local PostgreSQL (see development-local-setup-wsl2.md)"
fi

if ! docker info &>/dev/null; then
  log ""
  log "Cannot talk to the Docker daemon. Start Docker Desktop, enable WSL integration, or add your user to the 'docker' group:"
  log "  sudo usermod -aG docker \"\$USER\""
  log "  (then sign out of WSL and back in)"
  die "docker daemon unreachable"
fi

if ! git config --global --get core.autocrlf &>/dev/null; then
  git config --global core.autocrlf input
  log "Set git config --global core.autocrlf input (Windows/WSL shared checkouts)"
fi

if ! command -v rustc &>/dev/null; then
  log "Installing Rust via rustup (non-interactive)..."
  export RUSTUP_INIT_SKIP_PATH_CHECK="${RUSTUP_INIT_SKIP_PATH_CHECK:-yes}"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
else
  # shellcheck source=/dev/null
  [ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
fi

rustc --version

# Minimum Rust aligned with CONTRIBUTING.md (adjust if MSRV changes)
_rust_ver="$(rustc -Vv | awk '/^release:/{print $2}')"
_rust_minor="${_rust_ver#*.}"
_rust_minor="${_rust_minor%%.*}"
if [ "${_rust_ver%%.*}" = "1" ] && [ "${_rust_minor:-0}" -lt 94 ] 2>/dev/null; then
  log "Updating Rust toolchain (need 1.94+)..."
  rustup update stable
fi

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  log "Installing nvm ${NVM_VERSION}..."
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

if ! type nvm &>/dev/null; then
  die "nvm failed to load; open a new shell or: source \"\$HOME/.nvm/nvm.sh\""
fi

nvm install "${NODE_VERSION}"
nvm alias default "${NODE_VERSION}"
node --version
npm --version

log ""
log "Prerequisites finished. Next:"
log "  1. Clone the repo under your Linux home (e.g. ~/src/arcpanel), not under /mnt/c/."
log "  2. Run:  bash scripts/wsl2-setup-dev-environment.sh"
log "  3. Build panel crates + frontend, then:  bash scripts/wsl2-start-services.sh"
