#!/usr/bin/env bash
#
# Sets up a pairing HOST on macOS or native Linux: installs tmux + upterm +
# Claude Code, creates the dedicated unprivileged `pairing` user that
# sessions run as, and installs the `pair` command with your team's config
# (relay address, relay server key, who may join).
#
# Usage: ./install-unix.sh [--config <dir>] [--yes]
#   --config <dir>  your team's copy of the pairing-config template
#                   (default: ../pairing-config, next to this repo)
#   --yes           don't ask before making changes
#
# Windows users: don't run this directly — run install-windows.ps1 instead.
# It creates a dedicated WSL distro and then calls this same script from
# inside it (with --wsl-dedicated-distro).
#
# Safe to re-run: every step skips work that's already done. Re-run it after
# pulling changes to your pairing-config.
set -euo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

OS="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAIRING_USER="pairing"
CONF_DIR="/usr/local/share/pairing"
TEAM_CONFIG="$SCRIPT_DIR/../pairing-config"

WSL_DEDICATED_DISTRO=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)               TEAM_CONFIG="${2:?--config needs a directory}"; shift ;;
    --wsl-dedicated-distro) WSL_DEDICATED_DISTRO=1 ;;
    --yes|-y)               ASSUME_YES=1 ;;
    *) err "Unknown option: $1 (supported: --config <dir>, --yes)"; exit 1 ;;
  esac
  shift
done

# Your team's config (see the README's "Setup in four steps"). Fail before
# installing anything if it's missing or the relay isn't filled in yet.
# Stripping \r keeps a CRLF checkout on Windows from breaking it.
if [ ! -f "$TEAM_CONFIG/relay.conf" ] || [ ! -f "$TEAM_CONFIG/team_authorized_keys" ]; then
  err "No team config found in $TEAM_CONFIG."
  err "Create your team's private copy of the pairing-config template and clone it"
  err "next to this repo, or point to it with --config <dir>."
  exit 1
fi
TEAM_CONFIG="$(cd "$TEAM_CONFIG" && pwd)"
eval "$(tr -d '\r' < "$TEAM_CONFIG/relay.conf")"
if [ -z "${RELAY_HOST:-}" ] || [ -z "${RELAY_PORT:-}" ] || [ -z "${RELAY_SERVER_KEY:-}" ]; then
  err "$TEAM_CONFIG/relay.conf isn't filled in (RELAY_HOST / RELAY_PORT / RELAY_SERVER_KEY)."
  err "The relay comes first — see the README's \"2. Run your own relay\"."
  exit 1
fi
# known_hosts writes port 22 as a bare host name, any other port as [host]:port.
if [ "$RELAY_PORT" = 22 ]; then
  RELAY_PIN="$RELAY_HOST $RELAY_SERVER_KEY"
else
  RELAY_PIN="[$RELAY_HOST]:$RELAY_PORT $RELAY_SERVER_KEY"
fi

# Talks to the relay before anything is installed: is it up, and does it
# present the server key from relay.conf? A wrong key means a typo in
# relay.conf, a redeployed relay, or someone in between pretending to be
# it — in every case, stop rather than install against it.
check_relay() {
  local scanned
  scanned="$(ssh-keyscan -T 5 -p "$RELAY_PORT" -t "${RELAY_SERVER_KEY%% *}" "$RELAY_HOST" 2>/dev/null | grep -v '^#' | cut -d' ' -f2,3 || true)"
  if [ -z "$scanned" ]; then
    err "Can't reach the relay at $RELAY_HOST:$RELAY_PORT."
    err "Is it running, is port $RELAY_PORT open in its firewall, and is RELAY_HOST in relay.conf right?"
    exit 1
  fi
  if [ "$scanned" != "$RELAY_SERVER_KEY" ]; then
    err "The relay at $RELAY_HOST:$RELAY_PORT presents a different server key than relay.conf:"
    err "  relay.conf: $RELAY_SERVER_KEY"
    err "  relay:      $scanned"
    err "Either relay.conf is out of date, or something is impersonating the relay. Don't continue until you know which."
    exit 1
  fi
  say "Relay $RELAY_HOST:$RELAY_PORT is up and presents the expected server key"
}

# Uses whatever package manager the machine already has instead of bringing
# its own: Homebrew or MacPorts on macOS; the distro's own manager on Linux,
# with Homebrew as a fallback. Tools already on PATH are left alone, however
# they were installed.
detect_pkg_manager() {
  PM=""
  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then PM=brew
      elif command -v port >/dev/null 2>&1; then PM=port
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then PM=apt
      elif command -v dnf >/dev/null 2>&1; then PM=dnf
      elif command -v pacman >/dev/null 2>&1; then PM=pacman
      elif command -v brew >/dev/null 2>&1; then PM=brew
      fi
      ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
}

# pkg_install <tool>: installs tmux or node(+npm) with $PM, mapping to the
# package names each manager uses.
pkg_install() {
  local tool="$1"
  case "$PM:$tool" in
    brew:node)   brew install node ;;
    brew:*)      brew install "$tool" ;;
    port:node)   sudo port install nodejs22 npm10 ;;
    port:*)      sudo port install "$tool" ;;
    apt:*)       [ -n "${APT_UPDATED:-}" ] || { sudo apt-get update -qq; APT_UPDATED=1; }
                 if [ "$tool" = node ]; then sudo apt-get install -y nodejs npm; else sudo apt-get install -y "$tool"; fi ;;
    dnf:node)    sudo dnf install -y nodejs npm ;;
    dnf:*)       sudo dnf install -y "$tool" ;;
    pacman:node) sudo pacman -Sy --noconfirm nodejs npm ;;
    pacman:*)    sudo pacman -Sy --noconfirm "$tool" ;;
    *)
      err "No supported package manager found to install $tool."
      [ "$OS" = Darwin ] && err "Install Homebrew (https://brew.sh) or MacPorts, or install $tool yourself, then re-run."
      [ "$OS" = Linux ] && err "Install $tool with your distro's package manager, then re-run."
      exit 1
      ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# Lists exactly what this run is going to change on this machine, and asks
# before touching anything: people should know what they're installing.
confirm_plan() {
  say "This installer sets up this machine as a pairing HOST, using the team config"
  say "in $TEAM_CONFIG. It's about to make these changes:"
  say ""
  if have tmux; then say "  - tmux: already installed, left alone"; else say "  - install tmux (via $PM)"; fi
  if have upterm; then say "  - upterm: already installed, left alone"
  elif [ "$PM" = brew ]; then say "  - install upterm (via brew, owenthereal/upterm tap)"
  else say "  - install upterm (pinned release from github.com/owenthereal/upterm)"
  fi
  if have node; then say "  - Node.js: already installed, left alone"; else say "  - install Node.js + npm (via $PM)"; fi
  if have claude; then say "  - Claude Code: already installed, left alone"; else say "  - install Claude Code (npm install -g @anthropic-ai/claude-code)"; fi
  if id "$PAIRING_USER" >/dev/null 2>&1; then say "  - user account '$PAIRING_USER': already exists, left alone"
  else say "  - create a user account '$PAIRING_USER' (no admin rights, no password login) that sessions run as"
  fi
  say "  - install /usr/local/bin/pair, and its config in $CONF_DIR"
  say "  - create a relay login key for the '$PAIRING_USER' user (~$PAIRING_USER/.ssh/relay_login_key)"
  say "  - add the relay's server key ($RELAY_HOST:$RELAY_PORT) to your ~/.ssh/known_hosts"
  if [ "$WSL_DEDICATED_DISTRO" = 1 ]; then
    say "  - write /etc/wsl.conf: this distro loses access to Windows drives and Windows programs"
  fi
  say ""
  say "Why: anyone who joins a session gets a shell on this machine. See the README's"
  say "\"Read this first\" for what that means and what this setup limits."
  say ""
  [ "$ASSUME_YES" = 1 ] && return
  local answer
  read -r -p "Continue? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) say "Nothing changed."; exit 0 ;;
  esac
}

install_tmux() {
  if have tmux; then
    say "tmux already installed ($(tmux -V))"
    return
  fi
  pkg_install tmux
}

# Installs the upterm CLI. Deliberately does NOT pipe the official install
# script (curl | bash) into a shell — downloads the versioned release asset
# from GitHub instead, so it's a reviewable, pinned artifact rather than an
# unreviewed remote script executed blind.
install_upterm() {
  if command -v upterm >/dev/null 2>&1; then
    say "upterm already installed ($(upterm version | head -1))"
    return
  fi

  if [ "$PM" = brew ]; then
    brew install owenthereal/upterm/upterm
    return
  fi

  local arch plat api tmp url
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) err "Unsupported architecture for upterm: $arch"; exit 1 ;;
  esac
  [ "$OS" = "Darwin" ] && plat=darwin || plat=linux
  api="https://api.github.com/repos/owenthereal/upterm/releases/latest"
  tmp="$(mktemp -d)"

  if [ "$plat" = "linux" ] && command -v dpkg >/dev/null 2>&1; then
    url="$(curl -sf "$api" | grep -o "\"browser_download_url\": *\"[^\"]*upterm_linux_${arch}\.deb\"" | head -1 | cut -d'"' -f4)"
    [ -n "$url" ] || { err "Could not find an upterm .deb release asset for $arch."; exit 1; }
    curl -sfL "$url" -o "$tmp/upterm.deb"
    sudo dpkg -i "$tmp/upterm.deb"
  else
    url="$(curl -sf "$api" | grep -o "\"browser_download_url\": *\"[^\"]*upterm_${plat}_${arch}\.tar\.gz\"" | head -1 | cut -d'"' -f4)"
    [ -n "$url" ] || { err "Could not find an upterm release asset for ${plat}/${arch}."; exit 1; }
    curl -sfL "$url" -o "$tmp/upterm.tar.gz"
    tar -xzf "$tmp/upterm.tar.gz" -C "$tmp"
    sudo install -m 755 "$tmp/upterm" /usr/local/bin/upterm
  fi
  rm -rf "$tmp"
}

install_node_and_claude() {
  if ! have node; then
    pkg_install node
  fi
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$major" -lt 18 ]; then
    err "Node.js $(node -v) is too old for Claude Code (needs 18+) — upgrade it, then re-run."
    exit 1
  fi

  if command -v claude >/dev/null 2>&1; then
    say "Claude Code already installed ($(claude --version))"
    return
  fi
  npm install -g @anthropic-ai/claude-code || sudo npm install -g @anthropic-ai/claude-code
}

# Sessions run as this user, never as you: anyone who joins gets a full shell
# as the session's user (a new tmux window is one keystroke away), so it must
# not be able to read your home, your SSH keys, your Claude login, or sudo.
create_pairing_user() {
  if id "$PAIRING_USER" >/dev/null 2>&1; then
    say "User '$PAIRING_USER' already exists"
  else
    case "$OS" in
      Darwin)
        # Random password nobody knows (an empty one would allow logins),
        # hidden from the login window; only reachable via `sudo -u`.
        sudo sysadminctl -addUser "$PAIRING_USER" -fullName "Pairing session" \
          -shell /bin/zsh -home "/Users/$PAIRING_USER" \
          -password "$(openssl rand -base64 32)"
        sudo createhomedir -c -u "$PAIRING_USER" >/dev/null
        sudo dscl . create "/Users/$PAIRING_USER" IsHidden 1
        ;;
      Linux)
        sudo useradd -m -s /bin/bash "$PAIRING_USER"
        ;;
    esac
    say "Created user '$PAIRING_USER'"
  fi

  if id -nG "$PAIRING_USER" | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
    warn "User '$PAIRING_USER' is in an admin group (sudo/wheel/admin) — remove it, or every participant gets root."
  fi
}

# Tools installed into your own home (nvm, a user-level npm prefix, ...) are
# on *your* PATH but out of reach for the pairing user, and `pair` would then
# fail inside the session in confusing ways. Catch that here.
check_tools_usable_by_pairing_user() {
  local tool missing=""
  for tool in tmux upterm node claude; do
    sudo -u "$PAIRING_USER" -H env PATH="$PATH" sh -c "command -v $tool >/dev/null" \
      || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    err "Not usable by the '$PAIRING_USER' user:$missing"
    err "Probably installed inside your own home (e.g. Node via nvm). Install them system-wide, then re-run."
    exit 1
  fi
}

# Root-owned, so nobody inside a session (they're all $PAIRING_USER) can add
# their own key to the join list or swap the pinned relay server key.
install_pair_command() {
  sudo install -d -m 755 "$CONF_DIR" /usr/local/bin
  printf 'RELAY_HOST="%s"\nRELAY_PORT="%s"\n' "$RELAY_HOST" "$RELAY_PORT" | sudo tee "$CONF_DIR/relay.conf" >/dev/null
  tr -d '\r' < "$TEAM_CONFIG/team_authorized_keys" | sudo tee "$CONF_DIR/authorized_keys" >/dev/null
  printf '%s\n' "$RELAY_PIN" | sudo tee "$CONF_DIR/known_hosts" >/dev/null
  sudo chmod 644 "$CONF_DIR/relay.conf" "$CONF_DIR/authorized_keys" "$CONF_DIR/known_hosts"
  tr -d '\r' < "$SCRIPT_DIR/pair" | sudo tee /usr/local/bin/pair >/dev/null
  sudo chmod 755 /usr/local/bin/pair
  say "Installed 'pair' and its config in $CONF_DIR"

  if ! grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$CONF_DIR/authorized_keys"; then
    warn "team_authorized_keys has no keys yet — 'pair' will refuse to start until it does."
  fi
}

# The key `upterm host` logs in to the relay with. Dedicated and
# passphrase-less so sessions start non-interactively; it lives in the
# pairing user's home, so treat it as known to every past participant.
# The relay only lets it start sessions once it's in relay_authorized_hosts.
setup_relay_login_key() {
  sudo -u "$PAIRING_USER" -H sh -c '
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [ ! -f "$HOME/.ssh/relay_login_key" ]; then
      ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/relay_login_key" -C "relay login key ($(whoami)@$(hostname))" -q
    fi'
  RELAY_LOGIN_PUB="$(sudo -u "$PAIRING_USER" -H sh -c 'cat "$HOME/.ssh/relay_login_key.pub"')"
}

# Pins the relay's server key for *you* too, for when you join someone
# else's session with plain ssh: without it, the first join is a blind
# yes/no prompt that looks the same whether you reach the real relay or an
# impersonator (DNS hijack, malicious wifi/proxy). `pair` itself uses
# $CONF_DIR/known_hosts.
pin_relay_server_key() {
  local khfile="$HOME/.ssh/known_hosts"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$khfile"
  if grep -qF "$RELAY_PIN" "$khfile" 2>/dev/null; then
    say "Relay server key already pinned"
    return
  fi
  printf '%s\n' "$RELAY_PIN" >> "$khfile"
  say "Pinned relay server key in $khfile"
}

# The pairing user can only be kept out of your files if your home isn't
# readable by other users. Not changed automatically — just flagged.
check_home_permissions() {
  [ "$(id -un)" = "root" ] && return
  local mode
  if [ "$OS" = "Darwin" ]; then
    mode="$(stat -f %Lp "$HOME")"
    # On macOS every user, $PAIRING_USER included, shares the 'staff' group.
    if [ "${mode:1:2}" != "00" ]; then
      warn "Your home ($HOME) is mode $mode: '$PAIRING_USER' (and so every participant) can read parts of it. Consider: chmod 700 \"$HOME\""
    fi
  else
    mode="$(stat -c %a "$HOME")"
    if [ "${mode:2:1}" != "0" ]; then
      warn "Your home ($HOME) is mode $mode: '$PAIRING_USER' (and so every participant) can read parts of it. Consider: chmod 750 \"$HOME\""
    fi
  fi
}

# Only for the dedicated WSL distro install-windows.ps1 creates: cut the
# distro off from Windows. By default any WSL user — $PAIRING_USER included —
# can read/write all of C: via /mnt/c and run powershell.exe/cmd.exe as your
# Windows account; with these off, a participant is stuck inside the distro.
lockdown_wsl_distro() {
  sudo tee /etc/wsl.conf >/dev/null <<WSLCONF
# Written by pairing-setup's install-unix.sh — see the README.
[user]
default=$PAIRING_USER

[interop]
enabled=false
appendWindowsPath=false

[automount]
enabled=false
mountFsTab=false
WSLCONF
  say "Wrote /etc/wsl.conf (no Windows drives, no Windows executables)"
}

check_relay
detect_pkg_manager
confirm_plan
install_tmux
install_upterm
install_node_and_claude
create_pairing_user
check_tools_usable_by_pairing_user
install_pair_command
setup_relay_login_key
pin_relay_server_key
check_home_permissions
if [ "$WSL_DEDICATED_DISTRO" = 1 ]; then lockdown_wsl_distro; fi

say ""
say "Setup done."
say ""
# The relay only lets listed machines start sessions; tell the user whether
# this one is listed yet, going by their current pairing-config checkout.
if grep -qF "$(printf '%s' "$RELAY_LOGIN_PUB" | cut -d' ' -f2)" "$TEAM_CONFIG/relay_authorized_hosts" 2>/dev/null; then
  say "This machine's relay login key is in relay_authorized_hosts."
else
  say "One more step before 'pair' works: the relay doesn't know this machine yet."
  say "Add this line to relay_authorized_hosts in your pairing-config, via a pull request:"
  say ""
  say "  $RELAY_LOGIN_PUB"
  say ""
  say "Once it's merged, whoever runs the relay applies it with: ./deploy.sh <relay-host> --hosts-only"
fi
say ""
say "Then start a shared pairing session with:"
say "  pair"
say "It runs as the '$PAIRING_USER' user, so log in to Claude Code there once"
say "(run 'claude' inside the session) and clone the repos you pair on into its home."
say "Only people whose key is in team_authorized_keys can join."
