#!/usr/bin/env bash
#
# Pairing setup for macOS or native Linux: installs tmux + upterm + Claude
# Code, and generates a dedicated (passphrase-less) SSH key for upterm.
#
# Windows users: don't run this directly — run install-windows.ps1 instead.
# It bootstraps WSL/Ubuntu and then calls this same script from inside it.
#
# Safe to re-run: every step skips work that's already done.
set -euo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

OS="$(uname -s)"

# Acme-hosted uptermd relay (see README's "Security considerations" and
# "Relay operations" sections) — replaces the public uptermd.upterm.dev relay
# as of 2026-09-02, removing the third-party-operator trust concern. Change
# this if the relay is ever redeployed to a different host/port; re-verify
# the host key fingerprint below with `ssh-keyscan` whenever it does.
RELAY_HOST="91.98.165.67"
RELAY_PORT="2222"

install_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    say "tmux already installed ($(tmux -V))"
    return
  fi
  case "$OS" in
    Darwin)
      command -v brew >/dev/null 2>&1 || { err "Homebrew not found — install it from https://brew.sh first."; exit 1; }
      brew install tmux
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y tmux
      elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y tmux
      elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm tmux
      else err "No known package manager (apt/dnf/pacman) — install tmux manually."; exit 1
      fi
      ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
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

  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
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
  if ! command -v node >/dev/null 2>&1; then
    case "$OS" in
      Darwin) brew install node ;;
      Linux)
        if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y nodejs npm
        elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y nodejs npm
        else err "Install Node.js 18+ manually, then re-run this script."; exit 1
        fi
        ;;
    esac
  fi

  if command -v claude >/dev/null 2>&1; then
    say "Claude Code already installed ($(claude --version))"
    return
  fi
  npm install -g @anthropic-ai/claude-code || sudo npm install -g @anthropic-ai/claude-code
}

setup_upterm_key() {
  local key="$HOME/.ssh/upterm_key"
  if [ -f "$key" ]; then
    say "Reusing existing $key"
    return
  fi
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$key" -C "upterm pairing key ($(whoami)@$(hostname))" -q
  chmod 600 "$key"
  say "Generated $key"
}

# Pins our relay's own SSH host key (fingerprint verified independently via
# ssh-keyscan on 2026-09-02, see the README's "Security considerations"
# section) so joining clients get a hard failure instead of a blind yes/no
# prompt if it's ever spoofed on the network path (DNS hijack, malicious
# wifi/proxy) — that prompt otherwise offers no real protection since
# there's nothing yet in known_hosts to compare against.
pin_relay_host_key() {
  local khfile="$HOME/.ssh/known_hosts"
  local pin="[$RELAY_HOST]:$RELAY_PORT ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtlgjADMQEivVXXUBk+xNM4wE7LZzye+nc6xjZ0maP5"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$khfile"
  if grep -qF "$pin" "$khfile" 2>/dev/null; then
    say "Relay host key already pinned"
    return
  fi
  printf '%s\n' "$pin" >> "$khfile"
  say "Pinned relay host key in $khfile"
}

install_tmux
install_upterm
install_node_and_claude
setup_upterm_key
pin_relay_host_key

say ""
say "Setup done. Start a shared pairing session with:"
say "  upterm host -i ~/.ssh/upterm_key --server ssh://$RELAY_HOST:$RELAY_PORT -- tmux new -s pairing"
say "Share the printed 'ssh TOKEN@$RELAY_HOST -p $RELAY_PORT' link with your pairing partner."
say "Inside the session, 'claude' starts Claude Code for both of you to share."
