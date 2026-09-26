# What `join` does

`join` is how participants join a session. It lives in your team's
pairing-config, not in this repo, so participants only need that one repo:
[`join`](https://github.com/johantre/pairing-config/blob/main/join) for
macOS, Linux and WSL, and
[`join.ps1`](https://github.com/johantre/pairing-config/blob/main/join.ps1)
for native Windows (no WSL needed).

- [Using it](#using-it)
- [Getting on the team list](#getting-on-the-team-list)
- [What it checks, every run](#what-it-checks-every-run)
- [How it connects](#how-it-connects)
- [Windows specifics](#windows-specifics)

## Using it

From your pairing-config folder:

| | macOS / Linux / WSL | Windows (PowerShell) |
|---|---|---|
| **First time** — set up only | `./join` | `.\join.ps1` |
| **Each session** — with the token the host shared | `./join <token>` | `.\join.ps1 <token>` |
| **Or** paste the host's whole command, in quotes | `./join "ssh <token>@<host> -p <port>"` | `.\join.ps1 "ssh <token>@<host> -p <port>"` |

- **Needs:** an SSH client (built into macOS, Linux and Windows 10+) and a
  clone of your team's pairing-config. Nothing is installed.
- **Touches:** only your own `~/.ssh`.

## Getting on the team list

1. **Clone your team's pairing-config** — read access is enough; the pull
   request below can come from a fork or a branch.
2. **Run `join` once, without a token.** It creates your client key and
   prints the line to add.
3. **Add that line to `team_authorized_keys`** in a pull request.
4. **Wait for hosts to pick it up:** once merged, each host pulls
   pairing-config and re-runs their installer. Until a host has, their
   sessions won't let you in.

Removing someone (they left, lost a laptop) is deleting their line, the
same way.

Why a reviewed file rather than `upterm`'s own key lookups
(`--github-user`, `--gitlab-user`, ...): it works wherever your config is
hosted, and it's easier to reason about than whatever keys happen to be on
someone's account at the moment — including an old key from a lost laptop
nobody remembered to remove.

## What it checks, every run

Each step is skipped when it's already done:

1. **Your client key** — `~/.ssh/upterm_client_key`. Created if missing:
   ed25519, no passphrase (so joining doesn't prompt every time), a
   `you@machine` comment.
2. **The relay's server key, pinned** — taken from `relay.conf` and added
   to `~/.ssh/known_hosts` if missing.
   - Why: without it, the first connection is a blind yes/no prompt that
     looks the same whether you reach the real relay or an impersonator.
   - If `known_hosts` already has a **different** key for the relay, it
     stops: either the relay was redeployed with a new key (check with its
     admin, pull pairing-config), or something is impersonating it. It
     tells you how to remove the old entry once you know which.
3. **Your key on the team list** — checked in *your checkout* of
   pairing-config. If it isn't there, it prints the line for your pull
   request. This is a hint, not a gate: the host's installed copy is what
   counts, and yours may just be out of date (`git pull`).

Without a token it stops here.

## How it connects

- **Checks the command first:** a pasted command that points to a
  different relay host or port than `relay.conf` is refused — only join
  sessions on your own relay.
- **Then runs `ssh`** with:
  - `-i ~/.ssh/upterm_client_key` — your client key;
  - `-o IdentitiesOnly=yes` — offer *only* that key; an `ssh-agent` full
    of other keys otherwise hits "Too many authentication failures"
    first;
  - `-o StrictHostKeyChecking=yes` — never accept an unknown relay key;
  - the relay's host and port from `relay.conf`, and your token as the
    user name.
- **You land** directly in the shared `tmux` session.
- **If it fails** with `Permission denied (publickey)`: your key isn't in
  the host's installed team list yet (merged? host pulled and re-ran the
  installer?), or the session has ended. `join` says so.

## Windows specifics

- **`ssh.exe`:** built into Windows 10+. If it's missing, `join.ps1` says
  where to enable it (Settings → System → Optional features → OpenSSH
  Client).
- **Empty passphrase:** PowerShell drops or mangles an empty `""`
  argument to native programs, differently per PowerShell version.
  `join.ps1` runs `ssh-keygen` through `Start-Process` with one raw command
  line, so the key really gets no passphrase in every version.
- **Execution policy:** if PowerShell refuses with *"running scripts is
  disabled on this system"*, run it once via
  `powershell -ExecutionPolicy Bypass -File .\join.ps1 <token>`, or set
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` for your account.
