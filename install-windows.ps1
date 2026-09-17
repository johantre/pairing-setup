<#
.SYNOPSIS
  Pairing setup bootstrap for Windows: gets WSL2 + Ubuntu into a working
  state, then runs install-unix.sh (in this same folder) inside it.

.DESCRIPTION
  Windows has no native tmux/upterm build, so pairing sessions run inside
  WSL. This script exists because getting a fresh WSL/Ubuntu install to
  actually boot turned out to be non-obvious in practice (2026-08-28):

  - A stale WSL core package can make Ubuntu fail immediately with
    "Catastrophic failure / Wsl/Service/E_UNEXPECTED" on every launch —
    even right after a clean reboot, even as --user root. Confirmed fix:
    `wsl --update` (pulls a current core+kernel), then `wsl --shutdown`
    before retrying.
  - Ubuntu's first-run OOBE wizard (the username/password prompt, backed by
    wslsettings.exe) can crash outright instead of completing — confirmed
    via a Windows Error Reporting crash record. This script never relies on
    it: it creates the default user by hand as root instead.

.PARAMETER DistroUser
  Username to create inside the Ubuntu distro. Defaults to your Windows
  username.
#>
param(
  [string]$DistroUser = $env:USERNAME
)

$ErrorActionPreference = "Stop"

function Say($msg) { Write-Host $msg }

# 1. Make sure the WSL platform itself is present.
wsl --status *>$null
if ($LASTEXITCODE -ne 0) {
  Say "WSL isn't set up yet. Installing the platform (no distro yet)..."
  wsl --install --no-distribution
  Say "Reboot Windows now, then re-run this script to continue."
  exit 0
}

# 2. Always update the WSL core package first — see .DESCRIPTION above.
Say "Updating WSL core package..."
wsl --update

# 3. Make sure Ubuntu is registered.
$distros = (wsl -l -q) -replace "`0", "" | Where-Object { $_.Trim() -ne "" }
if ($distros -notcontains "Ubuntu") {
  Say "Installing the Ubuntu distro..."
  wsl --install -d Ubuntu --no-launch
}

# 4. Restart the WSL VM so the update actually takes effect, then verify it
#    actually boots before doing anything else.
wsl --shutdown
Start-Sleep -Seconds 3
$probe = wsl -d Ubuntu --user root -- echo OK 2>&1
if ($probe -notmatch "OK") {
  Say "Ubuntu still won't boot after 'wsl --update'."
  Say "Try rebooting Windows once (fixes a stuck fresh WSL kernel install more often than not), then re-run this script."
  exit 1
}

# 5. Create (or reuse) a real default user by hand, bypassing the
#    crash-prone OOBE wizard entirely.
wsl -d Ubuntu --user root -- id -u $DistroUser *>$null
if ($LASTEXITCODE -ne 0) {
  Say "Creating WSL user '$DistroUser'..."
  wsl -d Ubuntu --user root -- bash -c "useradd -m -s /bin/bash '$DistroUser' && usermod -aG sudo '$DistroUser' && echo '$DistroUser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$DistroUser && chmod 0440 /etc/sudoers.d/$DistroUser"
} else {
  Say "WSL user '$DistroUser' already exists."
}
wsl --manage Ubuntu --set-default-user $DistroUser

# 6. Hand off to the shared unix installer, run from inside WSL via the
#    Windows-mounted repo path (no need to copy anything into the distro).
$wslScriptDir = (wsl -d Ubuntu -- wslpath -a "$PSScriptRoot") -replace "`r", ""
Say "Running install-unix.sh inside WSL as '$DistroUser'..."
wsl -d Ubuntu -- bash -lc "bash '$wslScriptDir/install-unix.sh'"

Say ""
Say "Done. Open a WSL terminal (Windows Terminal 'Ubuntu' profile, or an IDE"
Say "terminal tab switched to WSL) and run:"
Say "  upterm host -i ~/.ssh/upterm_key -- tmux new -s pairing"
