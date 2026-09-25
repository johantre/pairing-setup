# Pairing setup (`upterm` + `tmux` + Claude Code)

Lets two or more people share one terminal, you can see each other typing
— including a shared Claude Code session — without the garbled cursor/prompt corruption you get from a
raw shared SSH/pty session. A raw shared pty has no input serialization, so
simultaneous keystrokes interleave and break escape sequences, and
mismatched client window sizes break full-screen TUI redraws (which is
exactly what Claude Code's interactive prompt is). The fix is a
multiplexer (`tmux`) *inside* the shared session to serialize input and
sync screen size; `upterm` just provides the secure tunnel to reach it.

![Diagram: a host on any OS (macOS/Linux/Windows+WSL2) runs `pair`, which shares one tmux session as the unprivileged pairing user over your own relay (host key pinned, only your hosts); clients on any OS join over SSH with a key listed in team_authorized_keys, while a client with only the token is denied. Below: a raw shared pty garbles each viewer's screen, while tmux inside the session keeps every screen identical.](pairing-topology.svg)

## Read this first: sharing a terminal hands out your machine

> [!CAUTION]
> **Used the way `upterm`'s own docs show it (`upterm host`), a pairing
> session gives everyone who joins full control of your computer, as
> you.** This setup exists to fix that. Read this section before running
> any installer, so you know what it puts on your machine and why.

### How an `upterm` session works

The problems below make more sense with the moving parts in mind:

1. **The host starts a session.** They run `upterm host`, which opens an
   SSH connection to a **relay server** (`uptermd`) and keeps it open. The
   host's machine doesn't need to be reachable from the internet; the
   relay is the meeting point.
2. **The relay hands out a session token.** A random string that
   identifies this one session. `upterm` prints it as a ready-made join
   command, with the token as the SSH user name:
   ```
   ssh <token>@uptermd.upterm.dev
   ```
3. **The host shares that command** with whoever should join — usually in
   a chat message.
4. **Participants run it.** Their `ssh` connects to the relay, the relay
   looks up the session by its token, and connects them to the host's
   terminal.

So the token is the session's address. As the next section shows, it's
also — by default — the only thing that decides who gets in.

### The problems

Out of the box, `upterm` comes with three separate security problems:

1. **Whoever joins gets your account.** `upterm host` shares a *shell
   running as your own user account*. Whoever joins isn't watching your
   Claude Code pane — they're typing into that shell. One `Ctrl-b c` opens
   a new `tmux` window of their own, and from there they can do anything
   you can:
   - read your SSH keys, cloud and `git` credentials, `.env` files,
     browser data, and your Claude Code login;
   - copy files off your machine (`upterm` allows `sftp`/`scp` by
     default), or push code and deploy with your credentials;
   - use `sudo` if your account can do so without a password — and the
     earlier Windows setup of this repo configured exactly that;
   - on Windows/WSL: read and write all of `C:` via `/mnt/c`, and start
     `powershell.exe` as your Windows account — the whole laptop, not
     just Linux;
   - leave something behind (a line in `~/.bashrc`, a `cron` job, an
     extra key in `~/.ssh/authorized_keys`) that keeps working after the
     session ends.
2. **Anyone with the token can join.** The session token (see
   [above](#how-an-upterm-session-works)) is not just the session's
   address but, by default, its only lock: `upterm` accepts any SSH key
   from whoever connects with it. So the join command effectively *is*
   the password — pasted in the wrong chat, forwarded, or visible in a
   screenshot or screen share, it's enough to get in.
3. **The default relay is a third party.** Every session goes through a
   relay server. Unless you pass `--server`, that's
   `uptermd.upterm.dev`: a free public service run by `upterm`'s
   maintainer, outside your organisation, with no contract or audit. The
   relay decrypts everything passing through, so it can read your screen
   and inject keystrokes into your shell — and on a hostile network, an
   attacker can pose as it. See
   [Why not `upterm`'s public relay](#why-not-upterms-public-relay).

Together: an unauthenticated remote shell as your own user, through a
server you don't control. On a developer machine with access to source
code, production credentials and customer data, that's a serious risk,
not a theoretical one.

### What this setup does about it

1. **Participants never get your account.** Sessions run as a separate,
   unprivileged `pairing` user — no `sudo`, no access to your home, your
   keys or your own Claude login. On Windows that user lives in a WSL
   distro of its own that can't see your Windows drives or start Windows
   programs. File transfer (`sftp`/`scp`) is off.
2. **Only your team can join.** `pair` only lets in keys listed in
   [`team_authorized_keys`](team_authorized_keys), reviewed via pull
   requests (see [Team keys](#team-keys)). The token alone is useless.
3. **Your own relay, pinned.** Sessions go through an `uptermd` relay you
   run yourself instead of the public one, and its host key is pinned so
   it can't be impersonated.

### What stays open

- **Participants are still the `pairing` user.** They can do everything
  that user can: read and change what you cloned into its home, use its
  Claude Code login, and use any credentials you give it — so give it
  scoped ones.
- **Your own relay still sees everything.** It's yours now, but it still
  decrypts sessions, so whoever gets into the relay server can read and
  type into them. Keep it locked down.
- **Trust.** This limits the damage; it doesn't make a stranger safe. Only
  pair with people you'd trust at your keyboard.

Details: [Security considerations](#security-considerations--open-points).

### What the installers put on the host machine

The installers are for **hosts**: the machine a session runs on. Only
joining other people's sessions? You don't need them at all — an SSH
client, which every OS ships with, and a key in the team list are enough
(see [Joining as a participant](#joining-as-a-participant)).

On a host, both installers list their changes and ask before doing
anything:

- `tmux`, `upterm`, `node` and Claude Code (`claude`) — skipped if already
  installed, otherwise via the package manager you already have (see
  [Install](#install));
- a user account named `pairing`, without admin rights or a usable
  password, that sessions run as (on Windows: a WSL distro named
  `pairing` containing that user, with no access to Windows);
- the `pair` command in `/usr/local/bin`, and its config (relay address,
  pinned relay key, team keys) in `/usr/local/share/pairing`, root-owned
  so nobody inside a session can change who may join;
- an SSH key for the `pairing` user to log in to the relay, and the
  relay's host key in your own `~/.ssh/known_hosts`.

Nothing else on the host is changed. The installers do *warn* if your
own home directory is readable by other users (the `pairing` user
included), and say how to fix it.

## Install

This sets up a **host**: a machine you'll start pairing sessions from.
Only joining? Skip to [Team keys](#team-keys) and
[Joining as a participant](#joining-as-a-participant).

### Once per team

- **Fork or clone this repo.** All commands below assume you're in its
  folder:
  ```
  git clone https://github.com/johantre/pairing-setup.git
  cd pairing-setup
  ```
- **Fill in [`relay.conf`](relay.conf)** with your relay's address and
  host key (see [Running your own relay](#running-your-own-relay)). The
  installers refuse to run until it is.
- **List your team in [`team_authorized_keys`](team_authorized_keys)**
  (see [Team keys](#team-keys)). Until it has at least one key, `pair`
  refuses to start.

Both files are specific to your team, which makes a fork the natural place
to keep them.

### macOS / native Linux

- **Run the installer:**
  ```
  ./install-unix.sh
  ```
  - It lists what it's going to change (see
    [above](#what-the-installers-put-on-the-host-machine)) and asks before
    doing anything; `--yes` skips the question.
  - It asks for your `sudo` password, to create the `pairing` user and
    install `pair`.
- **Tools you already have are left alone**, however you installed them.
  Missing ones come from the package manager already on your machine:

  | | `tmux`, `node` | `upterm` |
  |---|---|---|
  | **macOS** | `brew` (Homebrew), else `port` (MacPorts) | Homebrew tap, else pinned GitHub release |
  | **Linux** | `apt`, `dnf` or `pacman`, else `brew` | `brew` if that's the manager used, else pinned GitHub release (`.deb` on Debian/Ubuntu) |

  - On a Mac with neither Homebrew nor MacPorts: install one of them (most
    people use [Homebrew](https://brew.sh)) or the missing tools yourself,
    and re-run.
  - Claude Code always comes from `npm` (`@anthropic-ai/claude-code`).
- **Everything must be installed system-wide**, not just for your account,
  since sessions run as the `pairing` user. Tools inside your own home
  (e.g. `node` via `nvm`) can't be reached by it; the installer checks
  this and stops if so.

### Windows

- **Why WSL:** `tmux` has no native Windows build (`upterm` does, but the
  session still needs `tmux`), so the session runs inside WSL2.
- **Run the installer:**
  ```
  ./install-windows.ps1
  ```
  - If PowerShell refuses with *"running scripts is disabled on this
    system"*, that's its default execution policy, not a problem with the
    script. Either run it once via
    `powershell -ExecutionPolicy Bypass -File .\install-windows.ps1`, or
    set `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` for your
    account.
  - Installing the WSL platform requires one reboot if it's genuinely
    your first time; the script tells you when to re-run it.
- **What it does**, after asking for confirmation:
  - creates a **separate WSL distro named `pairing`** (an Ubuntu, next to
    any `Ubuntu` distro you may already have — that one isn't touched);
  - runs `install-unix.sh` inside it;
  - locks that distro down in `/etc/wsl.conf`: no `/mnt/c` (Windows drives
    aren't mounted) and no running Windows programs from inside it.
    Without that, any WSL user can read and write all of `C:` and start
    `powershell.exe` as your Windows account — so a participant would
    effectively be on your Windows machine.
- **No Windows package manager needed:** `winget`, Chocolatey or Scoop
  don't come into it. Nothing is installed on the Windows side except WSL
  itself, and inside WSL it's Ubuntu's `apt`.

### Re-running and updating

- **Both installers are safe to re-run**: every step skips work that's
  already done.
- **Re-run after pulling** changes to `relay.conf` or
  `team_authorized_keys`: `pair` uses the installed copies, not the repo.
- **Upgrading from the earlier setup on Windows?** That one ran sessions in
  your regular `Ubuntu` distro and gave its user password-less `sudo`
  (`/etc/sudoers.d/<you>`). Sessions now run in the `pairing` distro;
  consider removing that sudoers file from your `Ubuntu` if you don't need
  it.

## Team keys

[`team_authorized_keys`](team_authorized_keys) lists the public keys
allowed to join, one per line in the standard OpenSSH `authorized_keys`
format, with a `name@device` comment so it's obvious whose key it is:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... jan@macbook
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... piet@wsl
```
To be able to join, generate a small dedicated key once (no passphrase, so
joining doesn't prompt every time):

**macOS / Linux / WSL:**
```
ssh-keygen -t ed25519 -N "" -f ~/.ssh/upterm_client_key -C "$(whoami)@$(hostname)"
cat ~/.ssh/upterm_client_key.pub
```

**PowerShell (native Windows client):**
```
ssh-keygen -t ed25519 -N '""' -f $HOME\.ssh\upterm_client_key -C "$env:USERNAME@$env:COMPUTERNAME"
Get-Content $HOME\.ssh\upterm_client_key.pub
```
The `-N '""'` (not `-N ""`) is deliberate: PowerShell can silently drop a
bare empty-string argument to a native `.exe`, shifting the arguments after
it, so `ssh-keygen` ends up misparsing the command. Passing the literal
`""` characters through sidesteps that.

Add the printed line to `team_authorized_keys` in a pull request. Removing
someone (they left, lost a laptop) is deleting their line — effective for
every host that has pulled and re-run the installer.

Only public keys go in that file, so it's fine to commit. `upterm` can also
fetch keys itself (`--github-user`, `--gitlab-user`, `--codeberg-user`,
`--srht-user`), but a file under review works wherever your repo is hosted
and is easier to reason about than whatever keys happen to be on
someone's account at the moment — including an old key from a lost laptop
nobody remembered to remove.

## Use

Whoever's hosting runs, in a terminal:
```
pair
```
On Windows: `wsl -d pairing -- pair` from any terminal, or run `pair` in
the `pairing` profile that shows up in Windows Terminal / your IDE's
terminal list.

`upterm` shows the session details and asks once whether to start sharing;
confirm, and it prints a join command — share
`ssh TOKEN@<relay-host> -p <port>` with your pairing partner. Anything
after `pair` is passed on to `upterm host`, e.g. `pair --read-only` for a
session others can only watch.

The first time, log in to Claude Code inside the session (`claude`) and
clone the repos you pair on into the `pairing` user's home — it can't see
yours, which is the point. On Windows those files are reachable from your
IDE as `\\wsl.localhost\pairing\home\pairing\...`.

Both of you should be able to type without corrupting each other's view.
If it still looks broken, check `tmux`'s `window-size` session option
(`tmux show -g window-size`): the default, `smallest`, shrinks the shared
session to whichever attached client has the smaller terminal — usually
the right call. `set -g window-size manual` pins an explicit size instead
if you need to force one.

**Typing feels laggy joining from macOS?** `tmux` repaints a relatively
large chunk of the screen on every keystroke (the line, status bar, and
cursor position), and macOS's built-in `Terminal.app` redraws that
noticeably slower than most alternatives — this showed up as visible
input lag joining from `Terminal.app` while a Linux client on the same
session, same relay, had none. Try iTerm2, Ghostty, or kitty instead.

### Joining as a participant

Nothing to install: you need an SSH client (built into macOS, Linux and
Windows 10+) and a key listed in `team_authorized_keys` (see
[Team keys](#team-keys)).

**Once: pin the relay's host key**, with the values from `relay.conf`, so
`ssh` can tell the real relay from an impersonator. Hosts who ran the
installer already have this.

**macOS / Linux / WSL:**
```
echo "[<relay-host>]:<port> <RELAY_HOST_KEY>" >> ~/.ssh/known_hosts
```

**PowerShell (native Windows client):**
```
Add-Content $HOME\.ssh\known_hosts "[<relay-host>]:<port> <RELAY_HOST_KEY>"
```

**Then, for each session**, run the command the host shares, with the
key you added to `team_authorized_keys`:

**macOS / Linux / WSL:**
```
ssh -i ~/.ssh/upterm_client_key -p <port> TOKEN@<relay-host>
```

**PowerShell (native Windows client):**
```
ssh -i $HOME\.ssh\upterm_client_key -p <port> TOKEN@<relay-host>
```

You land directly in the shared `tmux` session. `Permission denied
(publickey)` means the key you offered isn't in the host's installed
`team_authorized_keys` — check your PR is merged and the host re-ran the
installer since. Re-run with `-v` to see which key `ssh` actually offered.

## Running your own relay

### Why not `upterm`'s public relay

`upterm` always goes through a relay server (`uptermd`): the host keeps an
SSH tunnel open to it, and participants connect to the relay, not to the
host. By default that's `uptermd.upterm.dev`, a free public relay run by
`upterm`'s maintainer. It works, and it's fine for a quick demo — but know
what you're trusting:

- **The relay sees everything in clear text.** Both connections are
  encrypted, but only up to the relay: `uptermd` decrypts traffic from one
  side and re-encrypts it for the other. It is not end-to-end encrypted.
  So the relay can read everything on screen and everything typed — your
  code, Claude's output, a secret you `cat` or paste.
- **The relay can also type.** It sits in the middle of an interactive
  shell, so whoever controls it can inject keystrokes: run commands on the
  host as the session's user. That makes the relay part of your attack
  surface, not just a pipe.
- **You have no say over who controls it.** A free public service run by
  someone outside your organisation, with no contract, no audit, and no
  notice if it's compromised or changes hands. It's also a shared target:
  breaking into one public relay exposes every session on it.
- **Anyone can pose as it.** Your first connection to a relay asks you to
  accept its host key without anything to compare against. On a hostile
  network (hotel wifi, a DNS hijack, a proxy that intercepts SSH) you
  could be accepting an attacker's relay, which then gets all of the
  above.
- **Availability.** If it's down or rate-limited, nobody can pair.

### What running your own relay fixes

- **The relay operator is you.** The relay runs on a server your
  organisation controls, so seeing and typing into sessions is limited to
  people who already have access to that server — the same trust you
  place in your other infrastructure.
- **Its identity is pinned.** Its host key is in [`relay.conf`](relay.conf)
  and installed into everyone's `known_hosts`, so an impersonated relay
  gets a hard error instead of a yes/no prompt.
- **Only your hosts can use it** (optional, recommended — step 4 below),
  so it's not an open relay for anyone on the internet.

What it doesn't fix: the relay still decrypts sessions — that's how `upterm`
works. Keep the relay server locked down (firewall, patched, few admins),
because whoever gets into it gets into every session.

### Setting it up

It's a single Go binary with one SSH port; any small Linux VM with a
public IP will do (any cloud provider — the cheapest tier is plenty).

`upterm`'s own docs list several ways to deploy it — a Helm chart for
Kubernetes, Fly.io, Heroku, Docker Compose behind Traefik, and a hardened
systemd unit: see
[Deploy Uptermd](https://github.com/owenthereal/upterm#deploy-uptermd).
Pick whichever fits what you already run. This repo's
[`deploy.sh`](deploy.sh) is the systemd route, scripted:

1. **Create the VM** and open inbound TCP **2222** (uptermd) plus your
   admin SSH port in its firewall. Nothing else needs to be reachable.
2. **Deploy** from your machine, over SSH as root (or a sudo user, `-u`):
   ```
   ./deploy.sh <relay-ip>
   ```
   It downloads a specific, checksum-verified `uptermd` release from
   GitHub and runs it as a sandboxed systemd service (dedicated non-root
   user, `ProtectSystem=strict`, `NoNewPrivileges`, ...) with a persistent
   host key in `/etc/uptermd/`. It ends by printing that host key as a
   ready-to-paste `RELAY_HOST_KEY="..."` line. Safe to re-run for updates:
   it reuses the host key rather than regenerating it (a new one would
   break every client's pinned `known_hosts` entry).
3. **Fill in [`relay.conf`](relay.conf)** — `RELAY_HOST`, `RELAY_PORT`,
   `RELAY_HOST_KEY` — and commit it. Before you do, confirm the key from a
   *different network* than the one you deployed from:
   ```
   ssh-keyscan -p 2222 -t ed25519 <relay-ip>
   ```
   Both should match; if they don't, something between you and the relay
   is rewriting traffic.
4. **Recommended: restrict who can host.** By default any `upterm` client
   that reaches port 2222 can host sessions on your relay. To allow only
   your team's hosts, collect the relay login keys the installer prints
   on each host (the `pairing` user's `~/.ssh/upterm_key.pub`) into an
   `authorized_keys`-format file and deploy with it:
   ```
   ./deploy.sh <relay-ip> --authorized-hosts relay_authorized_hosts
   ```
   It's kept on the relay; later deploys without the option keep using
   it. A host that isn't listed can't start a session there anymore, so
   add new hosts to it before they try.

To read the relay's host key again later (e.g. to confirm a redeploy
didn't change it):
```
ssh root@<relay-ip> 'ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub'
```
If it ever changes on purpose, update `relay.conf` and have everyone
re-run the installer, or joins will hard-fail with `REMOTE HOST
IDENTIFICATION HAS CHANGED` (correctly — but confusingly, if nobody
expects it).

## Security considerations — open points

- **Participants are the `pairing` user.** Everything that user can do,
  every participant can do: read and change the repos in its home, use
  its Claude Code login (so they can run Claude on your subscription or
  API key, and read its token), and use any git credentials you give it.
  Give it only what a pairing session needs — e.g. a repo-scoped deploy
  key or fine-grained token for pushing, not your personal key. Anything
  a participant leaves behind in its home (a `~/.bashrc` line) runs in
  later sessions as that user; if in doubt, recreate the user (or on
  Windows: `wsl --unregister pairing` and re-run the installer).
- **The relay sees everything, even your own.** See
  [Why not `upterm`'s public relay](#why-not-upterms-public-relay): running
  your own makes the operator yourself, it doesn't make the relay blind.
  Keep the relay VM locked down accordingly.
- **The host-key pin only protects what it was checked against.** It
  stops anyone between *you* and the relay from impersonating it, but if
  the key was captured through an already-compromised path, you've pinned
  the attacker. Hence the check from a second network in
  [Running your own relay](#running-your-own-relay).
- **`deploy.sh` hasn't been independently reviewed** beyond initial
  setup. It downloads a checksummed release and applies reasonable systemd
  sandboxing, but treat it as a starting point, not an audited artifact.
- **Passphrase-less keys.** The host's `upterm_key` (relay login) has no
  passphrase so `pair` starts non-interactively, and it lives in the
  `pairing` user's home — assume past participants have it. On a relay
  with `--authorized-hosts` that means they could host sessions on your
  relay; rotate it (delete it, re-run the installer, update the relay's
  list) if that matters. Participants' `upterm_client_key` is equally
  usable by anyone who gets a copy of the file; its line in
  `team_authorized_keys` is what to delete when that happens.

## Troubleshooting (Windows/WSL)

These are real failures hit while building this script, not hypotheticals:

- **`Catastrophic failure` / `Wsl/Service/E_UNEXPECTED` when launching
  the distro, even right after a reboot, even as `--user root`:** the
  installed WSL core package was stale (kernel 5.15) and incompatible
  with a "modern"-registration Ubuntu distro. `wsl --update` (pulls a
  current core+kernel) + `wsl --shutdown` fixed it outright. This is step
  2 of `install-windows.ps1` — if it still fails after that, reboot
  Windows once and re-run the script.
- **The first-run username/password wizard hangs or crashes:** confirmed
  via Windows Error Reporting to be `wslsettings.exe` crashing outright,
  not just a slow prompt. `install-windows.ps1` never relies on it —
  everything runs as root and `install-unix.sh` creates the `pairing`
  user itself.
- **`/mnt/c` is empty and `explorer.exe` / `code .` don't work in the
  `pairing` distro:** intended — see [Install](#install). Reach its files
  from Windows via `\\wsl.localhost\pairing\` instead.
- **Don't use the Windows-side `node`/`npm` from inside WSL** (e.g. an
  `nvm-windows` install reachable via `/mnt/c/...` through WSL interop) —
  it can resolve `npm` on `PATH` with no matching `node` binary, and
  mixing a Windows-side JS toolchain with a Linux one inside WSL is
  fragile in general. `install-unix.sh` always installs a native Node
  inside the distro.

## Why not the official `upterm` install script?

`install-unix.sh` downloads a specific, versioned release asset from
GitHub and installs it explicitly (`.deb`/`dpkg`, or a `.tar.gz` extracted
to `/usr/local/bin`) rather than piping `curl | bash` from `upterm`'s own
install script. Same end result, but it's a reviewable pinned artifact
instead of blind execution of an unreviewed remote script.
