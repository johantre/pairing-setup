# What `pair` does

`pair` is the one command a host types to start a session. It's a short
script ([`pair`](../pair)) that the installer puts in `/usr/local/bin`.

- [It switches to the `pairing` user](#it-switches-to-the-pairing-user)
- [It reads the team config — a root-owned copy](#it-reads-the-team-config--a-root-owned-copy)
- [It refuses to start without a join list](#it-refuses-to-start-without-a-join-list)
- [It starts `upterm host`, locked down](#it-starts-upterm-host-locked-down)
- [What happens next](#what-happens-next)

## It switches to the `pairing` user

- **What:** if you run it as yourself, it re-runs itself as the `pairing`
  user (`sudo -u pairing`), so it may ask for your `sudo` password.
- **Why:** anyone who joins gets a full shell as whichever user runs the
  session — not just a view of the `tmux` pane you're looking at. So it
  must never be you. See [Security → The problems](security.md#the-problems).
- **On Windows:** the `pairing` distro's default user already is
  `pairing`, so there's no switch and no password.

## It reads the team config — a root-owned copy

The installer copied your team's config into `/usr/local/share/pairing`:

- **`relay.conf`** — the relay's host and port.
- **`known_hosts`** — the relay's pinned server key.
- **`authorized_keys`** — the join list, from `team_authorized_keys`.

Why a root-owned copy instead of reading your pairing-config directly:
everyone in a session *is* the `pairing` user. If that user could write
these files, any participant could add their own key to the join list or
swap the relay's pinned key for later sessions.

## It refuses to start without a join list

- **What:** if `authorized_keys` has no keys, `pair` stops.
- **Why:** an empty list reaches the relay as "no list" — and for the
  relay, no list means **anyone with the token may join**. Without this
  check, an empty `team_authorized_keys` would silently bring back
  problem 2 from [Security](security.md#the-problems).

## It starts `upterm host`, locked down

Each flag closes one of the defaults described in
[Security](security.md#the-problems):

| Flag | What it does | Why |
|---|---|---|
| `-i ~/.ssh/relay_login_key` | logs in to the relay with this machine's relay login key | the relay only accepts hosts in `relay_authorized_hosts`; without `-i`, `upterm` would fall back to other keys |
| `--server ssh://<host>:<port>` | uses your own relay | instead of the public `uptermd.upterm.dev` |
| `--known-hosts /usr/local/share/pairing/known_hosts` | checks the relay's server key against the pinned one | an impersonated relay is refused instead of trusted |
| `--authorized-keys /usr/local/share/pairing/authorized_keys` | only these keys may join | the token alone isn't enough anymore |
| `--no-sftp` | no file transfer (`sftp`/`scp`) | by default participants could copy files off the host |
| `--force-command "tmux attach -t pairing"` | joiners land straight in the shared `tmux` session | instead of a separate shell of their own |
| your extra arguments | passed on as is | e.g. `pair --read-only` |
| `-- tmux new -A -s pairing` | the shared command: a `tmux` session named `pairing` | `-A` re-attaches if it's still running |

It also changes to the `pairing` user's home first, so the session starts
there and not in a directory of yours.

## What happens next

- **Confirmation:** `upterm` shows the session details and asks once
  whether to start sharing.
- **Join command:** it prints `ssh <token>@<relay-host> -p <port>` — share
  that with your partner, who runs it through [`join`](join.md).
- **Who checks the join list:** the host hands its list to the relay with
  the session, and the **relay** enforces it for each join. That's one
  reason the relay is the most sensitive part — see
  [Running your own relay](relay.md#the-relay-is-the-most-sensitive-part).
