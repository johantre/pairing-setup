# Troubleshooting

- [Joining](#joining)
- [The shared screen](#the-shared-screen)
- [Windows / WSL](#windows--wsl)

## Joining

- **`Permission denied (publickey)`:**
  - your key isn't in the host's *installed* team list yet — is your pull
    request merged, and did the host pull pairing-config and re-run their
    installer since?
  - or the session has ended, or the token is wrong.
- **`Too many authentication failures`:** `ssh` offered other keys first.
  `join` prevents this (`IdentitiesOnly=yes`); if you connect by hand, add
  `-o IdentitiesOnly=yes -i ~/.ssh/upterm_client_key`.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED`, or `join` says your
  `known_hosts` has a different key:** the relay presents another server
  key than the one you pinned. Either it was redeployed with a new key
  (ask its admin, pull pairing-config), or something is impersonating it.
  Don't remove the old entry until you know which. See
  [Checking the server key later](relay.md#checking-the-server-key-later).
- **The installer says it can't reach the relay:** is it running, is its
  port open in the VM's firewall, and is `RELAY_HOST` in `relay.conf`
  right?
- **`pair` starts but the relay refuses the host:** this machine's relay
  login key isn't in the relay's list yet. See
  [Let the relay know about the new host](host.md#let-the-relay-know-about-the-new-host).

## The shared screen

- **It still looks broken:** check `tmux`'s `window-size` session option
  (`tmux show -g window-size`).
  - The default, `smallest`, shrinks the shared session to whichever
    attached client has the smaller terminal — usually the right call.
  - `set -g window-size manual` pins an explicit size instead, if you need
    to force one.
- **Typing feels laggy joining from macOS:**
  - `tmux` repaints a relatively large chunk of the screen on every
    keystroke (the line, status bar, and cursor position), and macOS's
    built-in `Terminal.app` redraws that noticeably slower than most
    alternatives.
  - This showed up as visible input lag joining from `Terminal.app`, while
    a Linux client on the same session, same relay, had none.
  - Try iTerm2, Ghostty, or kitty instead.

## Windows / WSL

These are real failures hit while building the installer, not
hypotheticals:

- **`Catastrophic failure` / `Wsl/Service/E_UNEXPECTED` when launching the
  distro,** even right after a reboot, even as `--user root`:
  - Cause: the installed WSL core package was stale (kernel 5.15) and
    incompatible with a "modern"-registration Ubuntu distro.
  - Fix: `wsl --update` (pulls a current core+kernel) + `wsl --shutdown`.
    This is step 2 of `install-windows.ps1`; if it still fails after that,
    reboot Windows once and re-run the script.
- **The first-run username/password wizard hangs or crashes:**
  - Cause: confirmed via Windows Error Reporting to be `wslsettings.exe`
    crashing outright, not just a slow prompt.
  - `install-windows.ps1` never relies on it: everything runs as root, and
    `install-unix.sh` creates the `pairing` user itself.
- **`/mnt/c` is empty and `explorer.exe` / `code .` don't work in the
  `pairing` distro:** intended — see [Setting up a host → Windows](host.md#windows).
  Reach its files from Windows via `\\wsl.localhost\pairing\` instead.
- **Don't use the Windows-side `node`/`npm` from inside WSL** (e.g. an
  `nvm-windows` install reachable via `/mnt/c/...` through WSL interop):
  - it can resolve `npm` on `PATH` with no matching `node` binary;
  - mixing a Windows-side JS toolchain with a Linux one inside WSL is
    fragile in general.

  `install-unix.sh` always installs a native Node inside the distro.
