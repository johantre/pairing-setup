<#
.SYNOPSIS
  Pairing setup bootstrap for Windows: creates a dedicated, locked-down WSL2
  distro named "pairing", then runs install-unix.sh (in this same folder)
  inside it.

.DESCRIPTION
  Windows has no native tmux/upterm build, so pairing sessions run inside
  WSL. They get a distro of their own rather than your everyday Ubuntu:
  anyone who joins a session gets a full shell in it, and a regular WSL
  distro hands that shell all of C: (/mnt/c) plus powershell.exe/cmd.exe
  running as your Windows account. install-unix.sh switches both off in
  this distro (/etc/wsl.conf) and runs sessions as an unprivileged user.

  Getting a fresh WSL distro to actually boot turned out to be non-obvious
  in practice (2026-08-28):

  - A stale WSL core package can make Ubuntu fail immediately with
    "Catastrophic failure / Wsl/Service/E_UNEXPECTED" on every launch -
    even right after a clean reboot, even as --user root. Confirmed fix:
    `wsl --update` (pulls a current core+kernel), then `wsl --shutdown`
    before retrying.
  - Ubuntu's first-run OOBE wizard (the username/password prompt, backed by
    wslsettings.exe) can crash outright instead of completing - confirmed
    via a Windows Error Reporting crash record. This script never relies on
    it: everything runs as root, and install-unix.sh creates the user.

.PARAMETER Config
  Your team's copy of the pairing-config template. Defaults to a
  pairing-config folder next to this repo.
#>
param(
  [string]$Config = (Join-Path $PSScriptRoot "..\pairing-config")
)

$ErrorActionPreference = "Stop"

$Distro = "pairing"
$ConfigFiles = "relay.conf", "team_authorized_keys", "relay_authorized_hosts"

function Say($msg) { Write-Host $msg }

# 0a. The team config comes first (see the README's "Setup in four steps"):
#     stop before touching anything if it's missing or not filled in.
if (-not (Test-Path (Join-Path $Config "relay.conf")) -or -not (Test-Path (Join-Path $Config "team_authorized_keys"))) {
  Say "No team config found in $Config."
  Say "Create your team's private copy of the pairing-config template and clone it"
  Say "next to this repo, or point to it with -Config <path>."
  exit 1
}
$Config = (Resolve-Path $Config).Path
$relayConf = Get-Content (Join-Path $Config "relay.conf") -Raw
foreach ($var in "RELAY_HOST", "RELAY_PORT", "RELAY_SERVER_KEY") {
  if ($relayConf -notmatch "(?m)^$var=`"[^`"]+`"") {
    Say "$Config\relay.conf isn't filled in ($var is empty)."
    Say "The relay comes first - see the README's '2. Run your own relay'."
    exit 1
  }
}

# 0b. Say exactly what this is going to change, and ask first: people should
#     know what they're installing. install-unix.sh then runs with --yes.
Say "This installer sets up this machine as a pairing HOST, using the team"
Say "config in $Config. It's about to make these changes:"
Say ""
Say "  - install/update the WSL platform (Windows' built-in Linux subsystem)"
Say "  - create a separate WSL distro named '$Distro' (Ubuntu); an existing"
Say "    'Ubuntu' distro is not touched"
Say "  - inside it: install tmux, upterm, Node.js and Claude Code, create an"
Say "    unprivileged user '$Distro' that sessions run as, and install 'pair'"
Say "  - lock that distro down: no access to your Windows drives (C:) and"
Say "    no starting Windows programs from inside it"
Say ""
Say "Why: anyone who joins a session gets a shell on this machine. See the"
Say "README's 'Read this first' for what that means and what this setup limits."
Say ""
$answer = Read-Host "Continue? [y/N]"
if ($answer -notmatch '^(y|yes)$') { Say "Nothing changed."; exit 0 }

# 1. Make sure the WSL platform itself is present.
wsl --status *>$null
if ($LASTEXITCODE -ne 0) {
  Say "WSL isn't set up yet. Installing the platform (no distro yet)..."
  wsl --install --no-distribution
  Say "Reboot Windows now, then re-run this script to continue."
  exit 0
}

# 2. Always update the WSL core package first - see .DESCRIPTION above.
#    Also needed for `wsl --install --name` below.
Say "Updating WSL core package..."
wsl --update

# 3. Make sure the dedicated distro is registered (an Ubuntu under its own
#    name, next to any Ubuntu you already have - that one isn't touched).
$distros = (wsl -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($distros -notcontains $Distro) {
  Say "Installing an Ubuntu distro named '$Distro'..."
  wsl --install -d Ubuntu --name $Distro --no-launch
  if ($LASTEXITCODE -ne 0) {
    Say "Couldn't create the '$Distro' distro. 'wsl --install --name' needs a recent WSL - run 'wsl --update' and retry."
    exit 1
  }
}

# 4. Restart the WSL VM so the update actually takes effect, then verify it
#    actually boots before doing anything else.
wsl --shutdown
Start-Sleep -Seconds 3
$probe = wsl -d $Distro --user root -- echo OK 2>&1
if ($probe -notmatch "OK") {
  Say "The '$Distro' distro still won't boot after 'wsl --update'."
  Say "Try rebooting Windows once (fixes a stuck fresh WSL kernel install more often than not), then re-run this script."
  exit 1
}

# 5. Copy the installer and the team config into the distro through the
#    \\wsl$ share. Not via /mnt/c: after the first run the distro has no
#    Windows drives mounted anymore, on purpose.
$target = "\\wsl.localhost\$Distro\tmp\pairing-setup"
New-Item -ItemType Directory -Force "$target\config" | Out-Null
foreach ($f in "install-unix.sh", "pair") {
  Copy-Item -Force (Join-Path $PSScriptRoot $f) $target
}
foreach ($f in $ConfigFiles) {
  $src = Join-Path $Config $f
  if (Test-Path $src) { Copy-Item -Force $src "$target\config" }
}

# 6. Hand off to the shared unix installer, as root: it checks the relay,
#    creates the unprivileged 'pairing' user itself and locks the distro down.
Say "Running install-unix.sh inside the '$Distro' distro..."
wsl -d $Distro --user root -- bash /tmp/pairing-setup/install-unix.sh --config /tmp/pairing-setup/config --wsl-dedicated-distro --yes
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# 7. /etc/wsl.conf only applies on the distro's next start.
wsl --terminate $Distro

Say ""
Say "Done. Start a pairing session from any Windows terminal with:"
Say "  wsl -d $Distro -- pair"
Say "or open the '$Distro' profile in Windows Terminal / your IDE's terminal list and run 'pair'."
