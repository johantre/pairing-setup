# Pairing setup (`upterm` + `tmux` + Claude Code)

Lets two or more people share one terminal, you can see each other typing
— including a shared Claude Code session — without the garbled cursor/prompt corruption you get from a
raw shared SSH/pty session. A raw shared pty has no input serialization, so
simultaneous keystrokes interleave and break escape sequences, and
mismatched client window sizes break full-screen TUI redraws (which is
exactly what Claude Code's interactive prompt is). The fix is a
multiplexer (`tmux`) *inside* the shared session to serialize input and
sync screen size; `upterm` just provides the secure tunnel to reach it.

![Diagram: a host on any OS (macOS/Linux/Windows+WSL2) runs `pair`, which shares one tmux session as the unprivileged pairing user over your own relay (server key pinned, only your hosts); clients on any OS join over SSH with a key listed in team_authorized_keys, while a client with only the token is denied. Below: a raw shared pty garbles each viewer's screen, while tmux inside the session keeps every screen identical.](pairing-topology.svg)

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
2. **Only your team can join.** `pair` only lets in keys listed in your
   team's `team_authorized_keys`, reviewed via pull requests (see
   [step 4](#4-add-participants)). The token alone is useless.
3. **Your own relay, pinned and closed.** Sessions go through an `uptermd`
   relay you run yourself instead of the public one. Its server key is
   pinned so it can't be impersonated, and only your team's host machines
   can use it.

### What stays open

- **Participants are still the `pairing` user.** They can do everything
  that user can: read and change what you cloned into its home, use its
  Claude Code login, and use any credentials you give it — so give it
  scoped ones.
- **Your own relay is still trusted with everything.** It's yours now,
  but it still decrypts sessions and enforces who may join, so whoever
  gets into the relay server can read, type into, and join every session.
  Keep it locked down (see
  [The relay is the most sensitive part](#the-relay-is-the-most-sensitive-part)).
- **Trust.** This limits the damage; it doesn't make a stranger safe. Only
  pair with people you'd trust at your keyboard.

Details: [Security considerations](#security-considerations--open-points).

## Keys and tokens at a glance

Several keys are involved, and their names look alike. Each one proves
something different:

| | What | Belongs to | Private half | Public half goes in | Proves |
|---|---|---|---|---|---|
| **Relay server key** | `RELAY_SERVER_KEY` | the relay | on the relay, `/etc/uptermd/` | `relay.conf` → everyone's `known_hosts` | "I am the real relay" |
| **Relay login key** | `relay_login_key` | each host machine | the `pairing` user's `~/.ssh/` | `relay_authorized_hosts` | "this machine may start sessions on the relay" |
| **Client key** | `upterm_client_key` | each participant | the participant's `~/.ssh/` | `team_authorized_keys` | "this person may join a session" |
| **Session token** | — | one session | — (not a key) | the join command | nothing — it's only the session's address |

Two lists, two gates:

- **`relay_authorized_hosts`** is checked by the relay when a session
  *starts*: who may host.
- **`team_authorized_keys`** is checked when someone *joins*: who may take
  part. Being on one list doesn't put you on the other; someone who both
  hosts and joins has a relay login key on their host machine *and* a
  client key of their own.

## Setup in four steps

### Who does what

- **Relay admin** — whoever runs the relay server. Usually one or two
  people; they have `root` on it.
- **Host** — anyone who starts pairing sessions from their machine.
- **Participant** — anyone who joins them. Needs nothing installed, only
  a clone of the team's pairing-config, which has the `join` command.

One person can have several roles.

### Two repos

- **[pairing-setup](https://github.com/johantre/pairing-setup)** (this
  one, public): the tools for hosts and relay admins. Use it as is;
  `git pull` for updates.
- **[pairing-config](https://github.com/johantre/pairing-config)**
  (public template): your team's data — relay address, who may host, who
  may join — plus the `join` command for participants. Each team makes a
  **private** copy of it.

Participants only need pairing-config. Hosts and relay admins clone both,
next to each other; the scripts find the config there by default (or pass
`--config <path>`):
```
your-folder/
├── pairing-setup/     ← the tools (public)
└── pairing-config/    ← your team's private copy of the template
```

### The steps, in order

Each step needs the one before it:

1. **[Create your team's config](#1-create-your-teams-config)** — once per
   team.
2. **[Run your own relay](#2-run-your-own-relay)** — once per team, by the
   relay admin. The installers refuse to run until the relay is in
   `relay.conf` and reachable.
3. **[Install each host](#3-install-a-host)** — once per host machine, then
   the relay admin lets it in.
4. **[Add participants](#4-add-participants)** — once per person.

After that: [start and join sessions](#use).

## 1. Create your team's config

1. On GitHub, open
   [pairing-config](https://github.com/johantre/pairing-config) and click
   **Use this template → Create a new repository**.
2. Choose **Private**. The template is public; your filled-in copy says
   where your relay is and who's on your team, so it shouldn't be.
3. Clone it next to this repo:
   ```
   git clone https://github.com/johantre/pairing-setup.git
   git clone <your-private-pairing-config-url> pairing-config
   ```

Everyone who hosts needs read access to it; changes go through pull
requests, so who can merge there decides who gets into your sessions.

## 2. Run your own relay

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
- **The relay decides who joins.** The host hands its list of allowed
  keys to the relay, and the relay enforces it. Whoever controls the relay
  can let anyone in.
- **You have no say over who controls it.** A free public service run by
  someone outside your organisation, with no contract, no audit, and no
  notice if it's compromised or changes hands. It's also a shared target:
  breaking into one public relay exposes every session on it.
- **Anyone can pose as it.** Your first connection to a relay asks you to
  accept its server key without anything to compare against. On a hostile
  network (hotel wifi, a DNS hijack, a proxy that intercepts SSH) you
  could be accepting an attacker's relay, which then gets all of the
  above.
- **Availability.** If it's down or rate-limited, nobody can pair.

### What running your own relay fixes

- **The relay operator is you.** The relay runs on a server your
  organisation controls, so seeing and typing into sessions is limited to
  people who already have access to that server.
- **Its identity is pinned.** Its server key is in `relay.conf` and
  installed into everyone's `known_hosts`, so an impersonated relay gets a
  hard error instead of a yes/no prompt.
- **Only your hosts can use it.** The relay only accepts the machines in
  `relay_authorized_hosts`; it starts out closed.

### The relay is the most sensitive part

Running your own relay moves the risk, it doesn't remove it: the relay
still decrypts every session, can type into it, and enforces who may join.
Whoever gets into the relay server gets into every session. Treat it
accordingly:

- **Few admins.** Only the relay admins need `root` on it; hosts and
  participants never do.
- **Your cloud account** (where the VM runs) with two-factor
  authentication — whoever controls that controls the VM.
- **Admin SSH with keys only**, no password logins.
- **Firewall:** only the relay port (2222) and your admin SSH port open.
- **Keep it patched** (OS security updates), and re-run `deploy.sh`
  now and then for `uptermd` updates.

`deploy.sh` sandboxes `uptermd` itself (see below), but doesn't configure
the points above for you.

### Setting it up

`uptermd` is a single Go binary with one SSH port; any small Linux VM with
a public IP will do (any cloud provider — the cheapest tier is plenty).
`upterm`'s own docs list several ways to deploy it — a Helm chart for
Kubernetes, Fly.io, Heroku, Docker Compose behind Traefik, and a hardened
systemd unit: see
[Deploy Uptermd](https://github.com/owenthereal/upterm#deploy-uptermd).
This repo's [`deploy.sh`](deploy.sh) is the systemd route, scripted, and
the rest of this README assumes it:

1. **Create the VM** and open inbound TCP **2222** (`uptermd`) plus your
   admin SSH port in its firewall. Nothing else needs to be reachable.
   - Its public address is what everyone will connect to. A DNS name
     (e.g. `relay.example.com`) is handier than a bare IP: if the relay
     ever moves to another VM (taking its server key along), nothing
     changes for anyone. Whichever you pick, use that same form
     everywhere — `known_hosts` matches the exact name or IP.
   - Why 2222 and not 22: port 22 is taken by the VM's own SSH server,
     the one admins log in with. Any free port works (443 gets through
     more corporate firewalls), as long as it's the same in three places:
     `deploy.sh --ssh-addr 0.0.0.0:<port>`, the VM's firewall, and
     `RELAY_PORT`.
2. **Deploy** from your machine, over SSH as `root` (or a sudo user, `-u`):
   ```
   ./deploy.sh <relay-host>
   ```
   - It downloads a specific, checksum-verified `uptermd` release from
     GitHub and runs it as a sandboxed systemd service (dedicated non-root
     user, `ProtectSystem=strict`, `NoNewPrivileges`, ...).
   - It creates the relay's server key in `/etc/uptermd/`, and ends by
     printing it as a ready-to-paste `RELAY_SERVER_KEY="..."` line.
   - It applies `relay_authorized_hosts` from your pairing-config. Empty at
     this point, so the relay starts **closed**: nobody can host yet.
   - Safe to re-run for updates: it keeps the server key (a new one would
     break everyone's pinned `known_hosts` entry).
3. **Fill in `relay.conf`** in your pairing-config and commit it:
   - `RELAY_HOST`: the relay's address from step 1 — the same one you
     passed to `deploy.sh`.
   - `RELAY_PORT`: `uptermd`'s port, `2222` unless you changed it.
   - `RELAY_SERVER_KEY`: the line `deploy.sh` printed at the end.
4. **Double-check the server key over a different path** before anyone
   relies on it. `deploy.sh` printed it over *your* network connection; if
   something on that network intercepts SSH (a corporate proxy, a
   compromised router, a hijacked DNS entry), it could show you its own key
   there and again on every check you make from the same network — you'd
   be comparing the attacker with itself. So check from somewhere that
   attacker is unlikely to also sit:
   - **Best:** your cloud provider's web console, which doesn't go over
     SSH at all. Open a console on the VM and run
     `ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub`; compare the
     fingerprint with the one `deploy.sh` printed.
   - **Otherwise:** from another network (e.g. your phone's hotspot
     instead of the office network):
     ```
     ssh-keyscan -p 2222 -t ed25519 <relay-host>
     ```

   If they don't match, don't commit it: something between you and the
   relay is rewriting traffic.

### One relay per group that trusts each other

One pairing-config means one relay with one `team_authorized_keys`
list. Everyone on that list can join *any* session on that relay, as
long as they get hold of its token — and a token is only an address: it
leaks through a shared chat channel, a forwarded message, a screenshot.

- **If the people on the list trust each other** (one company, similar
  work), one relay and one pairing-config for all of them is fine, and
  the simplest to run. Outsiders stay out either way.
- **If a group must be kept apart** (customer data with stricter rules,
  another company), give it its own relay and its own pairing-config.
  That also keeps it out of view of the other relay's admins, who can see
  every session on their relay.

### Letting hosts in

When a new host's relay login key is merged into `relay_authorized_hosts`
(see [step 3](#3-install-a-host)), the relay admin pulls pairing-config
and applies the list:
```
./deploy.sh <relay-host> --hosts-only
```
That only uploads the list and restarts `uptermd` — it reads the list once
at startup. The restart **drops sessions in progress**, so do it when
nobody's pairing. Removing a host works the same way: delete its line,
merge, apply.

To read the relay's server key again later (e.g. to confirm a redeploy
didn't change it):
```
ssh root@<relay-host> 'ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub'
```
If it ever changes on purpose, update `relay.conf` and have everyone
re-pin it, or connections will hard-fail with `REMOTE HOST IDENTIFICATION
HAS CHANGED` (correctly — but confusingly, if nobody expects it).

## 3. Install a host

This sets up a **host**: a machine you'll start pairing sessions from.
Only joining? Skip to [step 4](#4-add-participants).

### What the installers put on the host machine

The installers are for **hosts** only. Before changing anything, they
check that your pairing-config is there and filled in, and that the relay
is up and presents the server key from `relay.conf`. Then they list their
changes and ask:

- `tmux`, `upterm`, `node` and Claude Code (`claude`) — skipped if already
  installed, otherwise via the package manager you already have;
- a user account named `pairing`, without admin rights or a usable
  password, that sessions run as (on Windows: a WSL distro named
  `pairing` containing that user, with no access to Windows);
- the `pair` command in `/usr/local/bin`, and a copy of your team config
  (relay address, pinned server key, team keys) in
  `/usr/local/share/pairing`, root-owned so nobody inside a session can
  change who may join;
- a relay login key for the `pairing` user, and the relay's server key in
  your own `~/.ssh/known_hosts`.

Nothing else on the host is changed. The installers do *warn* if your
own home directory is readable by other users (the `pairing` user
included), and say how to fix it.

### macOS / native Linux

- **Run the installer:**
  ```
  ./install-unix.sh
  ```
  - It asks for your `sudo` password, to create the `pairing` user and
    install `pair`. `--yes` skips the confirmation question;
    `--config <path>` points to a pairing-config elsewhere.
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

### Let the relay know about the new host

The installer ends by printing this machine's **relay login key** — unless
it's already in `relay_authorized_hosts`. Until it is, the relay refuses to
let this machine start sessions:

1. Add the printed line to `relay_authorized_hosts` in your pairing-config,
   in a pull request.
2. Once merged, the relay admin applies it (see
   [Letting hosts in](#letting-hosts-in)).

Only needed once per host machine, not per session.

### Re-running and updating

- **Both installers are safe to re-run**: every step skips work that's
  already done.
- **Re-run after pulling pairing-config** when `relay.conf` or
  `team_authorized_keys` changed: `pair` uses the installed copies, not
  the repo.
- **Upgrading from the earlier setup on Windows?** That one ran sessions in
  your regular `Ubuntu` distro and gave its user password-less `sudo`
  (`/etc/sudoers.d/<you>`). Sessions now run in the `pairing` distro;
  consider removing that sudoers file from your `Ubuntu` if you don't need
  it.

## 4. Add participants

`team_authorized_keys` in your pairing-config lists the public keys
allowed to join, one per line in the standard OpenSSH `authorized_keys`
format, with a `name@device` comment so it's obvious whose key it is:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... jan@macbook
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... piet@wsl
```
A new participant:

1. **Clones the team's pairing-config** (read access is enough; the pull
   request below can come from a fork or a branch).
2. **Runs `join` once, without a token**, from inside that folder:
   - macOS / Linux / WSL: `./join`
   - Windows (PowerShell, no WSL needed): `.\join.ps1`

   It creates a dedicated client key (`~/.ssh/upterm_client_key`, no
   passphrase so joining doesn't prompt every time), pins the relay's
   server key, and prints the line to add to the team list.
3. **Adds that line to `team_authorized_keys`** in a pull request.

Once it's merged, hosts pick it up by pulling pairing-config and
re-running their installer. Removing someone (they left, lost a laptop)
is deleting their line, the same way.

`upterm` can also fetch keys itself (`--github-user`, `--gitlab-user`,
`--codeberg-user`, `--srht-user`), but a reviewed file works wherever your
config is hosted and is easier to reason about than whatever keys happen
to be on someone's account at the moment — including an old key from a
lost laptop nobody remembered to remove.

## Use

### Starting a session (host)

Run, in a terminal:
```
pair
```
On Windows: `wsl -d pairing -- pair` from any terminal, or run `pair` in
the `pairing` profile that shows up in Windows Terminal / your IDE's
terminal list.

`upterm` shows the session details and asks once whether to start sharing;
confirm, and it prints a join command — share
`ssh TOKEN@<relay-host> -p <port>` with your pairing partner, who pastes
it into `join` (see below). Anything
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

Nothing to install: an SSH client (built into macOS, Linux and Windows
10+) and your team's pairing-config are all you need (see
[step 4](#4-add-participants) for the one-time part). From the
pairing-config folder, pass `join` the token the host shared — or paste
the whole command they shared, quotes around it:

**macOS / Linux / WSL:**
```
./join <token>
./join "ssh <token>@<relay-host> -p <port>"
```

**Windows (PowerShell):**
```
.\join.ps1 <token>
.\join.ps1 "ssh <token>@<relay-host> -p <port>"
```

Every run first checks the one-time setup (client key, pinned relay
server key, your key on the team list) and redoes whatever is missing,
then connects with the right key, host and port. It refuses a command
that points to a different relay than the one in `relay.conf`.

You land directly in the shared `tmux` session. `Permission denied
(publickey)` means your key isn't in the host's installed
`team_authorized_keys` yet — check your PR is merged and the host pulled
and re-ran the installer since.

If PowerShell refuses with *"running scripts is disabled on this
system"*: run it once via
`powershell -ExecutionPolicy Bypass -File .\join.ps1 <token>`, or set
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` for your account.

## Security considerations — open points

- **Participants are the `pairing` user.** Everything that user can do,
  every participant can do: read and change the repos in its home, use
  its Claude Code login (so they can run Claude on your subscription or
  API key, and read its token), and use any `git` credentials you give it.
  Give it only what a pairing session needs — e.g. a repo-scoped deploy
  key or fine-grained token for pushing, not your personal key. Anything
  a participant leaves behind in its home (a `~/.bashrc` line) runs in
  later sessions as that user; if in doubt, recreate the user (or on
  Windows: `wsl --unregister pairing` and re-run the installer).
- **The relay is trusted with everything.** See
  [The relay is the most sensitive part](#the-relay-is-the-most-sensitive-part):
  running your own makes the operator yourself, it doesn't make the relay
  blind.
- **The server-key pin only protects what it was checked against.** It
  stops anyone between *you* and the relay from impersonating it, but if
  the key was captured through an already-compromised path, you've pinned
  the attacker. Hence the check from a second network in
  [Setting it up](#setting-it-up).
- **`deploy.sh` hasn't been independently reviewed** beyond initial
  setup. It downloads a checksummed release and applies reasonable systemd
  sandboxing, but treat it as a starting point, not an audited artifact.
- **Passphrase-less keys.** A host's `relay_login_key` has no passphrase
  so `pair` starts non-interactively, and it lives in the `pairing`
  user's home — assume past participants have it, which lets them start
  sessions on your relay. Rotate it if that matters: delete it, re-run the
  installer, and swap the line in `relay_authorized_hosts`. A
  participant's `upterm_client_key` is equally usable by anyone who gets a
  copy of the file; its line in `team_authorized_keys` is what to delete
  when that happens.

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
  `pairing` distro:** intended — see [Windows](#windows). Reach its files
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
