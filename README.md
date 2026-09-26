# Pairing setup (`upterm` + `tmux` + Claude Code)

Share one terminal — including a Claude Code session — with your team,
from any OS, without handing out your machine.

- **See each other type**, in one shared session, without the garbled
  cursor and prompt of a raw shared terminal.
- **Share Claude Code**: one session, everyone at the keyboard.
- **Without the risks** of a plain `upterm` session: participants don't
  get your account, only your team can join, and sessions go through your
  own relay.

![Diagram: a host on any OS (macOS/Linux/Windows+WSL2) runs `pair`, which shares one tmux session as the unprivileged pairing user over your own relay (server key pinned, only your hosts, join list enforced); clients on any OS join with `join` and a key listed in team_authorized_keys, while a client with only the token is denied. Below: a raw shared pty garbles each viewer's screen, while tmux inside the session keeps every screen identical.](pairing-topology.svg)

## What it's built on

- **`upterm`** shares a terminal over SSH, through a relay server both
  sides connect to — no open ports on the host.
  → [How it works](docs/how-it-works.md#upterm-sharing-a-terminal)
- **`tmux`** runs inside the shared session, so simultaneous typing and
  different window sizes don't garble anyone's screen.
  → [Why `tmux`](docs/how-it-works.md#tmux-why-it-runs-inside-the-session)

## Why not plain `upterm`

> [!CAUTION]
> Used the way `upterm`'s own docs show it, a pairing session gives
> everyone who joins **full control of your computer, as you**.

- **Whoever joins gets your account** — your keys, credentials, files,
  and on Windows your whole `C:` drive.
- **Anyone with the session token can join** — and a token leaks through
  a chat, a screenshot, a forwarded message.
- **The default relay is a third party** that can read and type into
  every session.

→ [The problems in detail](docs/security.md#the-problems)

## What this setup does about it

- **Participants never get your account:** sessions run as a separate,
  unprivileged `pairing` user; on Windows in a WSL distro cut off from
  Windows.
  → [What `pair` does](docs/pair.md)
- **Only your team can join:** a reviewed list of keys; the token alone is
  useless.
  → [Getting on the team list](docs/join.md#getting-on-the-team-list)
- **Your own relay, pinned and closed:** its identity is pinned, and only
  your team's machines can use it.
  → [Running your own relay](docs/relay.md)
- **What stays open** — participants are still the `pairing` user, and the
  relay still sees everything.
  → [What stays open](docs/security.md#what-stays-open)

## Get started

> [!IMPORTANT]
> **Nothing works without a relay.** Hosting and joining both go through
> it, and the installers refuse to run until your team's `relay.conf`
> points to one that's up. So the order is fixed:
> **1. team config + relay → 2. hosts → 3. participants.**
> Already done for your team? Skip to [Host sessions](#2-host-sessions) or
> [Join a session](#3-join-a-session).

### 1. Set up for your team (once)

Each step needs the one before it:

1. **Create your team's config:** on GitHub, open
   [pairing-config](https://github.com/johantre/pairing-config), click
   **Use this template**, and choose **Private**.
2. **Get a relay** and fill in `relay.conf` with its address and server
   key. Two ways:
   - **Your own** (recommended) — the relay admin sets it up with
     `deploy.sh`; it starts closed.
     → [Running your own relay](docs/relay.md)
   - **`upterm`'s public relay** — nothing to run, but a third party sees
     and can type into every session.
     → [Using the public relay instead](docs/relay.md#using-the-public-relay-instead)
3. **Install each host** — see [Host sessions](#2-host-sessions).
4. **Add participants** — see [Join a session](#3-join-a-session).

→ [Roles and repos](docs/how-it-works.md#roles-and-repos)

### 2. Host sessions

Needs: step 1 done — your team's pairing-config, with a relay in it.

1. **Clone this repo next to your team's pairing-config.**
2. **Run the installer:**
   - macOS / Linux: `./install-unix.sh`
   - Windows: `./install-windows.ps1`
3. **Get this machine onto the relay's list:** the installer prints a line
   for `relay_authorized_hosts`; add it in a pull request. (Not needed on
   the public relay.)
4. **Start a session** with `pair`, and share the join command it prints.

→ [Setting up a host](docs/host.md)

### 3. Join a session

Needs: step 1 done, and a host who starts a session. You need nothing
installed — only an SSH client and your team's
[pairing-config](https://github.com/johantre/pairing-config), which has
the `join` command.

1. **Clone your team's pairing-config.**
2. **Run `join` once** (`./join`, or `.\join.ps1` on Windows): it sets up
   your key and prints a line to add to the team list in a pull request.
3. **Join with the token** the host shares: `./join <token>`.

→ [What `join` does](docs/join.md)

## Documentation

- **[How it works](docs/how-it-works.md)** — `upterm`, `tmux`, how a
  session runs, and every key and token involved.
- **[Security](docs/security.md)** — the problems, what this setup does
  about them, and what stays open.
- **[Running your own relay](docs/relay.md)** — why, how, and how to keep
  it safe.
- **[Setting up a host](docs/host.md)** — the installers, per OS.
- **[What `pair` does](docs/pair.md)** — inside the host's command.
- **[What `join` does](docs/join.md)** — inside the participant's command.
- **[Troubleshooting](docs/troubleshooting.md)** — joining, the shared
  screen, Windows/WSL.
