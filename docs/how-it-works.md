# How it works

- [`upterm`: sharing a terminal](#upterm-sharing-a-terminal)
- [`tmux`: why it runs inside the session](#tmux-why-it-runs-inside-the-session)
- [How a session works, step by step](#how-a-session-works-step-by-step)
- [Keys and tokens at a glance](#keys-and-tokens-at-a-glance)
- [Roles and repos](#roles-and-repos)

## `upterm`: sharing a terminal

- **What it does:** [`upterm`](https://github.com/owenthereal/upterm)
  shares a terminal session over SSH. The host runs `upterm host`; others
  join with a plain `ssh` command, from any OS.
- **No open ports on the host:** the host's machine doesn't need to be
  reachable from the internet. Both sides connect *out* to a relay server
  (`uptermd`), which is the meeting point.
- **What it doesn't solve by itself:** who may join, what they can reach
  once in, and who runs the relay. That's what this setup adds — see
  [Security](security.md).

## `tmux`: why it runs inside the session

- **The problem with a raw shared terminal:** `upterm` on its own shares
  one pty (pseudo-terminal) between everyone. It has no input
  serialization, so:
  - simultaneous keystrokes interleave and break escape sequences;
  - clients with different window sizes break full-screen redraws — which
    is exactly what Claude Code's interactive prompt is.

  The result is the garbled cursor and prompt in the diagram's bottom half.
- **The fix:** a terminal multiplexer, `tmux`, *inside* the shared session.
  It serializes input and keeps every attached client's screen identical,
  so it doesn't matter who typed what, or from which OS.
- **How this setup uses it:** `pair` starts `tmux new -A -s pairing` as the
  shared command, and joining clients are attached straight to that
  session (see [What `pair` does](pair.md)).

## How a session works, step by step

1. **The host starts a session.** `pair` runs `upterm host`, which opens an
   SSH connection to the **relay** and keeps it open.
2. **The relay hands out a session token.** A random string that
   identifies this one session. `upterm` prints it as a ready-made join
   command, with the token as the SSH user name:
   ```
   ssh <token>@<relay-host> -p <port>
   ```
3. **The host shares that command** with whoever should join — usually in
   a chat message.
4. **Participants join.** `join` connects to the relay, the relay looks up
   the session by its token, checks the participant's key against the join
   list, and connects them to the host's terminal.

So the token is the session's **address**, not its lock. Out of the box
it's also the only thing that decides who gets in — see
[Security → The problems](security.md#the-problems).

## Keys and tokens at a glance

Several keys are involved, and their names look alike. Each proves
something different:

| | Name | Belongs to | Private half | Public half goes in | Proves |
|---|---|---|---|---|---|
| **Relay server key** | `RELAY_SERVER_KEY` | the relay | on the relay, `/etc/uptermd/` | `relay.conf` → everyone's `known_hosts` | "I am the real relay" |
| **Relay login key** | `relay_login_key` | each host machine | the `pairing` user's `~/.ssh/` | `relay_authorized_hosts` | "this machine may start sessions on the relay" |
| **Client key** | `upterm_client_key` | each participant | the participant's `~/.ssh/` | `team_authorized_keys` | "this person may join a session" |
| **Session token** | — | one session | — (not a key) | the join command | nothing — it's only the session's address |

Two lists, two gates:

- **`relay_authorized_hosts`** — checked by the relay when a session
  *starts*: who may host.
- **`team_authorized_keys`** — checked by the relay when someone *joins*:
  who may take part. The host hands this list to the relay with each
  session.
- **Being on one list doesn't put you on the other.** Someone who both
  hosts and joins has a relay login key on their host machine *and* a
  client key of their own.

## Roles and repos

**Three roles** — one person can have several:

- **Relay admin:** runs the relay server; has `root` on it. Usually one or
  two people.
- **Host:** starts pairing sessions from their machine, with `pair`.
- **Participant:** joins them, with `join`. Needs nothing installed.

**Two repos:**

- **[pairing-setup](https://github.com/johantre/pairing-setup)** (public):
  the tools for hosts and relay admins. Used as is; `git pull` for
  updates.
- **[pairing-config](https://github.com/johantre/pairing-config)** (public
  template): a team's data — relay address, who may host, who may join —
  plus the `join` command. Each team makes a **private** copy.
- **Who can change it:** changes to your pairing-config go through pull
  requests, so whoever can merge there decides who gets into your
  sessions. Everyone else only needs read access.
- **Who needs what:** participants only need pairing-config. Hosts and
  relay admins clone both, next to each other; the scripts find the config
  there by default (or pass `--config <path>`):
  ```
  your-folder/
  ├── pairing-setup/     ← the tools (public)
  └── pairing-config/    ← your team's private copy of the template
  ```
