#!/usr/bin/env bash
#
# Deploy uptermd to a remote host over SSH.
#
# Downloads the uptermd release tarball on the remote host, installs the binary
# to /usr/local/bin, and runs it as a systemd service.
#
# Usage:
#   ./deploy.sh <ip-address> [options]
#
# Options:
#   -u, --user USER       SSH user (default: root)
#   -p, --port PORT       SSH port (default: 22)
#   -v, --version VER     uptermd version to install, e.g. 0.24.0 (default: latest)
#   -a, --arch ARCH       amd64 | arm64 | ppc64le | s390x (default: detect on host)
#       --ssh-addr ADDR   uptermd ssh listen address (default: 0.0.0.0:2222)
#       --ws-addr ADDR    uptermd websocket listen address (default: 127.0.0.1:8080)
#       --authorized-hosts FILE
#                         authorized_keys file of the upterm host keys allowed
#                         to host sessions on this relay. Stored on the relay;
#                         later deploys without this option keep using it.
#   -h, --help            Show this help
#
# Examples:
#   ./deploy.sh 203.0.113.10
#   ./deploy.sh 203.0.113.10 --user root --version 0.24.0
#   ./deploy.sh 203.0.113.10 --authorized-hosts relay_authorized_hosts

set -euo pipefail

SSH_USER="root"
SSH_PORT="22"
VERSION="latest"
ARCH=""
UPTERMD_SSH_ADDR="0.0.0.0:2222"
UPTERMD_WS_ADDR="127.0.0.1:8080"
AUTHORIZED_HOSTS_FILE=""
HOST=""

usage() {
  sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//;s/^#$//'
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)     SSH_USER="${2:?missing value for $1}"; shift 2 ;;
    -p|--port)     SSH_PORT="${2:?missing value for $1}"; shift 2 ;;
    -v|--version)  VERSION="${2:?missing value for $1}"; shift 2 ;;
    -a|--arch)     ARCH="${2:?missing value for $1}"; shift 2 ;;
    --ssh-addr)    UPTERMD_SSH_ADDR="${2:?missing value for $1}"; shift 2 ;;
    --ws-addr)     UPTERMD_WS_ADDR="${2:?missing value for $1}"; shift 2 ;;
    --authorized-hosts) AUTHORIZED_HOSTS_FILE="${2:?missing value for $1}"; shift 2 ;;
    -h|--help)     usage 0 ;;
    -*)            die "unknown option: $1" ;;
    *)
      [[ -n "$HOST" ]] && die "unexpected argument: $1"
      HOST="$1"; shift ;;
  esac
done

[[ -n "$HOST" ]] || { echo "error: missing <ip-address>" >&2; echo >&2; usage 1; }

# Passed along base64-encoded in the environment: stdin is already taken by
# the remote script itself.
AUTHORIZED_HOSTS_B64=""
if [[ -n "$AUTHORIZED_HOSTS_FILE" ]]; then
  grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$AUTHORIZED_HOSTS_FILE" \
    || die "$AUTHORIZED_HOSTS_FILE has no keys — that would lock every host out"
  AUTHORIZED_HOSTS_B64="$(tr -d '\r' < "$AUTHORIZED_HOSTS_FILE" | base64 | tr -d '\n')"
fi

echo "==> Deploying uptermd ($VERSION) to ${SSH_USER}@${HOST}:${SSH_PORT}"

ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" \
  "VERSION='$VERSION' ARCH='$ARCH' UPTERMD_SSH_ADDR='$UPTERMD_SSH_ADDR' UPTERMD_WS_ADDR='$UPTERMD_WS_ADDR' AUTHORIZED_HOSTS_B64='$AUTHORIZED_HOSTS_B64' bash -s" <<'REMOTE'
set -euo pipefail

SUDO=""
[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

# --- detect architecture -----------------------------------------------------
if [[ -z "${ARCH}" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    ppc64le)       ARCH="ppc64le" ;;
    s390x)         ARCH="s390x" ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
fi

# --- resolve version ---------------------------------------------------------
if [[ "${VERSION}" == "latest" ]]; then
  echo "--> Resolving latest release"
  # Buffer the response and match in-shell: piping curl into an early-exiting
  # consumer (grep -m1, head) closes the pipe under it and trips curl error 23.
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/owenthereal/upterm/releases/latest)"
  if [[ "${RELEASE_JSON}" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "error: could not resolve latest version from GitHub API" >&2; exit 1
  fi
fi
VERSION="${VERSION#v}"

TARBALL="uptermd_linux_${ARCH}.tar.gz"
BASE_URL="https://github.com/owenthereal/upterm/releases/download/v${VERSION}"

# --- download & verify -------------------------------------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "--> Downloading ${TARBALL} (v${VERSION})"
curl -fsSL -o "${TMPDIR}/${TARBALL}" "${BASE_URL}/${TARBALL}"

echo "--> Verifying checksum"
if curl -fsSL -o "${TMPDIR}/checksums.txt" "${BASE_URL}/checksums.txt"; then
  ( cd "${TMPDIR}" && grep " ${TARBALL}\$" checksums.txt | sha256sum -c - )
else
  echo "    warning: checksums.txt unavailable, skipping verification" >&2
fi

echo "--> Installing /usr/local/bin/uptermd"
tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}" uptermd
$SUDO install -m 0755 "${TMPDIR}/uptermd" /usr/local/bin/uptermd

# --- service account & host key ----------------------------------------------
if ! id uptermd >/dev/null 2>&1; then
  echo "--> Creating uptermd system user"
  $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin uptermd
fi

$SUDO install -d -m 0750 -o uptermd -g uptermd /etc/uptermd
if [[ ! -f /etc/uptermd/ssh_host_ed25519_key ]]; then
  echo "--> Generating server host key"
  $SUDO ssh-keygen -t ed25519 -N '' -C uptermd -f /etc/uptermd/ssh_host_ed25519_key
  $SUDO chown uptermd:uptermd /etc/uptermd/ssh_host_ed25519_key*
  $SUDO chmod 0600 /etc/uptermd/ssh_host_ed25519_key
fi

# --- which hosts may register sessions ---------------------------------------
# Without an allowlist, anyone who can reach the SSH port can host their own
# sessions on this relay; with one, only the listed upterm host keys can.
if [[ -n "${AUTHORIZED_HOSTS_B64}" ]]; then
  echo "--> Installing /etc/uptermd/authorized_hosts"
  echo "${AUTHORIZED_HOSTS_B64}" | base64 -d | $SUDO tee /etc/uptermd/authorized_hosts >/dev/null
  $SUDO chown uptermd:uptermd /etc/uptermd/authorized_hosts
  $SUDO chmod 0640 /etc/uptermd/authorized_hosts
fi
AUTHORIZED_KEYS_ARG=""
if [[ -f /etc/uptermd/authorized_hosts ]]; then
  AUTHORIZED_KEYS_ARG="--authorized-keys /etc/uptermd/authorized_hosts"
else
  echo "    note: no /etc/uptermd/authorized_hosts, so any host can register sessions" >&2
fi

# --- systemd unit ------------------------------------------------------------
echo "--> Writing systemd unit"
$SUDO tee /etc/systemd/system/uptermd.service >/dev/null <<UNIT
[Unit]
Description=Upterm daemon
Documentation=https://github.com/owenthereal/upterm
After=network-online.target
Wants=network-online.target

[Service]
User=uptermd
Group=uptermd
ExecStart=/usr/local/bin/uptermd \\
  --ssh-addr ${UPTERMD_SSH_ADDR} \\
  --ws-addr ${UPTERMD_WS_ADDR} \\
  --private-key /etc/uptermd/ssh_host_ed25519_key ${AUTHORIZED_KEYS_ARG}
Restart=on-failure
RestartSec=5s
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/uptermd

[Install]
WantedBy=multi-user.target
UNIT

echo "--> Starting uptermd"
$SUDO systemctl daemon-reload
$SUDO systemctl enable uptermd
$SUDO systemctl restart uptermd

sleep 2
$SUDO systemctl --no-pager --lines=15 status uptermd || true
echo
echo "Installed: $(/usr/local/bin/uptermd version | sed -n 1p)"
echo "  ssh-addr: ${UPTERMD_SSH_ADDR}"
echo "  ws-addr:  ${UPTERMD_WS_ADDR}"
echo
echo "Relay host key for relay.conf (verify it from a second network too):"
echo "  RELAY_HOST_KEY=\"$(cut -d' ' -f1,2 /etc/uptermd/ssh_host_ed25519_key.pub)\""
echo "  fingerprint: $(ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub)"
REMOTE

echo "==> Done. uptermd is running on ${HOST}"
