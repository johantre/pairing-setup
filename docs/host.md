# Setting up a host

A **host** is a machine you start pairing sessions from. Only joining?
You don't need any of this — see [What `join` does](join.md).

- [Before you start](#before-you-start)
- [What the installer puts on the host machine](#what-the-installer-puts-on-the-host-machine)
- [macOS / native Linux](#macos--native-linux)
- [Windows](#windows)
- [Let the relay know about the new host](#let-the-relay-know-about-the-new-host)
- [Starting a session](#starting-a-session)
- [Picking up new participants, and other updates](#picking-up-new-participants-and-other-updates)
- [Why not `upterm`'s own install script?](#why-not-upterms-own-install-script)

## Before you start

- **Your team's pairing-config** cloned next to this repo (or pass
  `--config <path>`, `-Config <path>` on Windows). See
  [Roles and repos](how-it-works.md#roles-and-repos).
- **A running relay**, filled in in `relay.conf`. See
  [Running your own relay](relay.md). The installer checks both and stops
  before changing anything if either is missing.

## What the installer puts on the host machine

Before changing anything, the installer checks that your pairing-config is
there and filled in, and that the relay is up and presents the server key
from `relay.conf`. Then it lists its changes and asks:

- **Tools:** `tmux`, `upterm`, `node` and Claude Code (`claude`) — skipped
  if already installed, otherwise via the package manager you already
  have.
- **A user account named `pairing`**, without admin rights or a usable
  password, that sessions run as. On Windows: a WSL distro named `pairing`
  containing that user, with no access to Windows.
- **The `pair` command** in `/usr/local/bin`, and a copy of your team
  config (relay address, pinned server key, team keys) in
  `/usr/local/share/pairing` — root-owned, so nobody inside a session can
  change who may join. See [What `pair` does](pair.md).
- **Keys:** a relay login key for the `pairing` user, and the relay's
  server key in your own `~/.ssh/known_hosts` (for when you join others).

Nothing else on the host is changed. The installer does *warn* if your own
home directory is readable by other users (the `pairing` user included),
and says how to fix it.

## macOS / native Linux

- **Run the installer:**
  ```
  ./install-unix.sh
  ```
  - It asks for your `sudo` password, to create the `pairing` user and
    install `pair`.
  - `--yes` skips the confirmation question; `--config <path>` points to a
    pairing-config elsewhere.
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

## Windows

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
  - `-Config <path>` points to a pairing-config elsewhere.
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
- **Upgrading from the earlier setup?** That one ran sessions in your
  regular `Ubuntu` distro and gave its user password-less `sudo`
  (`/etc/sudoers.d/<you>`). Sessions now run in the `pairing` distro;
  consider removing that sudoers file from your `Ubuntu` if you don't need
  it.

## Let the relay know about the new host

- **Why:** the relay only lets listed machines start sessions (see
  [Keys and tokens at a glance](how-it-works.md#keys-and-tokens-at-a-glance)).
- **What the installer shows:** at the end it prints this machine's
  **relay login key** — unless it's already in `relay_authorized_hosts`.
- **What to do:**
  1. Add the printed line to `relay_authorized_hosts` in your
     pairing-config, in a pull request.
  2. Once merged, the relay admin applies it (see
     [Letting hosts in](relay.md#letting-hosts-in)).
- **How often:** once per host machine, not per session.
- **On the public relay:** not needed — it lets any machine host (see
  [Using the public relay instead](relay.md#using-the-public-relay-instead)).

## Starting a session

- **Run** `pair` in a terminal. On Windows: `wsl -d pairing -- pair` from
  any terminal, or `pair` in the `pairing` profile that shows up in
  Windows Terminal / your IDE's terminal list.
- **Confirm:** `upterm` shows the session details and asks once whether to
  start sharing.
- **Share** the join command it prints (`ssh <token>@<relay-host> -p <port>`)
  with your pairing partner, who passes it to `join`.
- **Options:** anything after `pair` goes to `upterm host`, e.g.
  `pair --read-only` for a session others can only watch.
- **The first time:**
  - log in to Claude Code inside the session (`claude`);
  - clone the repos you pair on into the `pairing` user's home — it can't
    see yours, which is the point. On Windows those files are reachable
    from your IDE as `\\wsl.localhost\pairing\home\pairing\...`.
- **What happens inside:** [What `pair` does](pair.md).

## Picking up new participants, and other updates

- **Re-run the installer after pulling pairing-config** when
  `team_authorized_keys` or `relay.conf` changed: `pair` uses the
  installed copies, not the repo. That's how new participants get in, and
  removed ones get out.
- **Safe to re-run:** every step skips work that's already done.

## Why not `upterm`'s own install script?

- **What the installer does instead:** it downloads a specific, versioned
  `upterm` release asset from GitHub and installs it explicitly
  (`.deb`/`dpkg`, or a `.tar.gz` extracted to `/usr/local/bin`).
- **Why:** same end result as piping `curl | bash` from `upterm`'s own
  install script, but a reviewable pinned artifact instead of blind
  execution of an unreviewed remote script.
