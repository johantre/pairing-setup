#!/usr/bin/env bash
#
# Deploy uptermd (the relay) to a server over SSH, or update which hosts may
# use it.
#
# Downloads the uptermd release tarball on the server, installs the binary
# to /usr/local/bin, and runs it as a systemd service. Only the host machines
# listed in your pairing-config's relay_authorized_hosts can start sessions
# on it; an empty list means nobody can, yet.
#
# Usage:
#   ./deploy.sh <relay-host> [options]
#
# Options:
#       --config DIR      your team's copy of the pairing-config template
#                         (default: ../pairing-config, next to this repo)
#       --hosts-only      only upload relay_authorized_hosts and restart the
#                         relay: for adding/removing hosts after the first
#                         deploy. The restart drops sessions in progress.
#   -u, --user USER       SSH user (default: root)
#   -p, --port PORT       SSH port (default: 22)
#   -v, --version VER     uptermd version to install, e.g. 0.24.0 (default: latest)
#   -a, --arch ARCH       amd64 | arm64 | ppc64le | s390x (default: detect on server)
#       --ssh-addr ADDR   uptermd ssh listen address (default: 0.0.0.0:2222)
#       --ws-addr ADDR    uptermd websocket listen address (default: 127.0.0.1:8080)
#   -h, --help            Show this help
#
# Examples:
#   ./deploy.sh 203.0.113.10
#   ./deploy.sh 203.0.113.10 --version 0.24.0
#   ./deploy.sh 203.0.113.10 --hosts-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAM_CONFIG="$SCRIPT_DIR/../pairing-config"
HOSTS_ONLY=0
SSH_USER="root"
SSH_PORT="22"
VERSION="latest"
ARCH=""
UPTERMD_SSH_ADDR="0.0.0.0:2222"
UPTERMD_WS_ADDR="127.0.0.1:8080"
HOST=""

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//;s/^#$//'
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      TEAM_CONFIG="${2:?missing value for $1}"; shift 2 ;;
    --hosts-only)  HOSTS_ONLY=1; shift ;;
    -u|--user)     SSH_USER="${2:?missing value for $1}"; shift 2 ;;
    -p|--port)     SSH_PORT="${2:?missing value for $1}"; shift 2 ;;
    -v|--version)  VERSION="${2:?missing value for $1}"; shift 2 ;;
    -a|--arch)     ARCH="${2:?missing value for $1}"; shift 2 ;;
    --ssh-addr)    UPTERMD_SSH_ADDR="${2:?missing value for $1}"; shift 2 ;;
    --ws-addr)     UPTERMD_WS_ADDR="${2:?missing value for $1}"; shift 2 ;;
    -h|--help)     usage 0 ;;
    -*)            die "unknown option: $1" ;;
    *)
      [[ -n "$HOST" ]] && die "unexpected argument: $1"
      HOST="$1"; shift ;;
  esac
done

[[ -n "$HOST" ]] || { echo "error: missing <relay-host>" >&2; echo >&2; usage 1; }

# --- which hosts may start sessions (from the team config) -------------------
HOSTS_FILE="$TEAM_CONFIG/relay_authorized_hosts"
[[ -f "$HOSTS_FILE" ]] || die "no $HOSTS_FILE — create your team's pairing-config first, or pass --config DIR"

# uptermd silently stops reading at the first line it can't parse, dropping
# every key after it — so refuse a file with a broken line instead.
HOST_KEY_COUNT=0
LINE_NO=0
while IFS= read -r line || [[ -n "$line" ]]; do
  LINE_NO=$((LINE_NO + 1))
  line="${line%$'\r'}"
  [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
  ssh-keygen -lf <(printf '%s\n' "$line") >/dev/null 2>&1 \
    || die "$HOSTS_FILE line $LINE_NO isn't a valid public key: $line"
  HOST_KEY_COUNT=$((HOST_KEY_COUNT + 1))
done < "$HOSTS_FILE"

if [[ "$HOST_KEY_COUNT" -eq 0 ]]; then
  echo "note: relay_authorized_hosts has no keys — the relay will be closed: nobody can start sessions yet." >&2
else
  echo "==> $HOST_KEY_COUNT host(s) in relay_authorized_hosts"
fi

# Passed along base64-encoded in the environment: stdin is already taken by
# the remote script itself.
AUTHORIZED_HOSTS_B64="$(tr -d '\r' < "$HOSTS_FILE" | base64 | tr -d '\n')"

if [[ "$HOSTS_ONLY" -eq 1 ]]; then
  echo "==> Updating the allowed hosts on ${SSH_USER}@${HOST}:${SSH_PORT} (restarts the relay)"
else
  echo "==> Deploying uptermd ($VERSION) to ${SSH_USER}@${HOST}:${SSH_PORT}"
fi

ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" \
  "HOSTS_ONLY='$HOSTS_ONLY' VERSION='$VERSION' ARCH='$ARCH' UPTERMD_SSH_ADDR='$UPTERMD_SSH_ADDR' UPTERMD_WS_ADDR='$UPTERMD_WS_ADDR' AUTHORIZED_HOSTS_B64='$AUTHORIZED_HOSTS_B64' bash -s" <<'REMOTE'
set -euo pipefail

SUDO=""
[[ "$(id -u)" -eq 0 ]] || SUDO="sudo"

install_authorized_hosts() {
  echo "--> Installing /etc/uptermd/authorized_hosts"
  echo "${AUTHORIZED_HOSTS_B64}" | base64 -d | $SUDO tee /etc/uptermd/authorized_hosts >/dev/null
  $SUDO chown uptermd:uptermd /etc/uptermd/authorized_hosts
  $SUDO chmod 0640 /etc/uptermd/authorized_hosts
}

# --- hosts-only: swap the list, restart, done --------------------------------
# uptermd reads the list once at startup, hence the restart.
if [[ "${HOSTS_ONLY}" == "1" ]]; then
  if ! grep -q -- '--authorized-keys /etc/uptermd/authorized_hosts' /etc/systemd/system/uptermd.service 2>/dev/null; then
    echo "error: this relay wasn't deployed with a host allowlist yet — run a full deploy (without --hosts-only) first" >&2
    exit 1
  fi
  install_authorized_hosts
  echo "--> Restarting uptermd"
  $SUDO systemctl restart uptermd
  sleep 2
  $SUDO systemctl --no-pager --lines=5 status uptermd || true
  exit 0
fi

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

# --- service account & server key --------------------------------------------
if ! id uptermd >/dev/null 2>&1; then
  echo "--> Creating uptermd system user"
  $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin uptermd
fi

$SUDO install -d -m 0750 -o uptermd -g uptermd /etc/uptermd
if [[ ! -f /etc/uptermd/ssh_host_ed25519_key ]]; then
  echo "--> Generating the relay's server key"
  $SUDO ssh-keygen -t ed25519 -N '' -C uptermd -f /etc/uptermd/ssh_host_ed25519_key
  $SUDO chown uptermd:uptermd /etc/uptermd/ssh_host_ed25519_key*
  $SUDO chmod 0600 /etc/uptermd/ssh_host_ed25519_key
fi

# --- which hosts may start sessions ------------------------------------------
# Always passed to uptermd, even when empty: an empty list means nobody can
# host, whereas no list at all would let anyone on the internet host here.
install_authorized_hosts

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
  --private-key /etc/uptermd/ssh_host_ed25519_key \\
  --authorized-keys /etc/uptermd/authorized_hosts
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
echo "The relay's server key, for relay.conf in your pairing-config"
echo "(check it from a second network too: ssh-keyscan -p <port> -t ed25519 <relay-host>):"
echo "  RELAY_SERVER_KEY=\"$(cut -d' ' -f1,2 /etc/uptermd/ssh_host_ed25519_key.pub)\""
echo "  fingerprint: $(ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub)"
REMOTE

if [[ "$HOSTS_ONLY" -eq 1 ]]; then
  echo "==> Done. The relay on ${HOST} now accepts the hosts in relay_authorized_hosts."
else
  echo "==> Done. uptermd is running on ${HOST}"
fi
