# Security

- [The problems](#the-problems)
- [What this setup does about them](#what-this-setup-does-about-them)
- [What stays open](#what-stays-open)
- [Open points](#open-points)

## The problems

Used the way `upterm`'s own docs show it (`upterm host`), a pairing
session gives everyone who joins **full control of your computer, as
you**. That comes down to three separate problems:

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
   [How a session works](how-it-works.md#how-a-session-works-step-by-step))
   is not just the session's address but, by default, its only lock:
   `upterm` accepts any SSH key from whoever connects with it. So the join
   command effectively *is* the password — pasted in the wrong chat,
   forwarded, or visible in a screenshot or screen share, it's enough to
   get in.
3. **The default relay is a third party.** Every session goes through a
   relay server. Unless you pass `--server`, that's `uptermd.upterm.dev`:
   a free public service run by `upterm`'s maintainer, outside your
   organisation, with no contract or audit. The relay decrypts everything
   passing through, can type into your shell, decides who may join — and
   on a hostile network, an attacker can pose as it. Details in
   [Relay → Why not the public relay](relay.md#why-not-upterms-public-relay).

Together: an unauthenticated remote shell as your own user, through a
server you don't control. On a developer machine with access to source
code, production credentials and customer data, that's a serious risk,
not a theoretical one.

## What this setup does about them

1. **Participants never get your account.**
   - Sessions run as a separate, unprivileged `pairing` user: no `sudo`,
     no access to your keys or your own Claude login.
   - On Windows that user lives in a WSL distro of its own that can't see
     your Windows drives or start Windows programs.
   - File transfer (`sftp`/`scp`) is off.
   - How: [What `pair` does](pair.md) and
     [Setting up a host](host.md#what-the-installer-puts-on-the-host-machine).
2. **Only your team can join.**
   - `pair` only lets in keys listed in your team's `team_authorized_keys`,
     reviewed via pull requests. The token alone is useless.
   - How: [Getting on the team list](join.md#getting-on-the-team-list)
     and [What `pair` does](pair.md#it-starts-upterm-host-locked-down).
3. **Your own relay, pinned and closed.**
   - Sessions go through an `uptermd` relay you run yourself instead of
     the public one.
   - Its server key is pinned, so it can't be impersonated.
   - Only your team's host machines can use it; it starts out closed.
   - How: [Running your own relay](relay.md).

## What stays open

- **Participants are still the `pairing` user.** They can do everything
  that user can: read and change what you cloned into its home, use its
  Claude Code login, and use any credentials you give it — so give it
  scoped ones.
- **Your own relay is still trusted with everything.** It's yours now,
  but it still decrypts sessions and enforces who may join, so whoever
  gets into the relay server can read, type into, and join every session.
  See [The relay is the most sensitive part](relay.md#the-relay-is-the-most-sensitive-part).
- **The team list is shared per relay.** Everyone on it can join any
  session on that relay once they have its token. See
  [One relay per group that trusts each other](relay.md#one-relay-per-group-that-trusts-each-other).
- **Trust.** This limits the damage; it doesn't make a stranger safe. Only
  pair with people you'd trust at your keyboard.

## Open points

- **Participants are the `pairing` user — plan for it.**
  - Everything that user can do, every participant can do: read and change
    the repos in its home, use its Claude Code login (so they can run
    Claude on your subscription or API key, and read its token), and use
    any `git` credentials you give it.
  - Give it only what a pairing session needs — e.g. a repo-scoped deploy
    key or fine-grained token for pushing, not your personal key.
  - Anything a participant leaves behind in its home (a `~/.bashrc` line)
    runs in later sessions as that user. If in doubt, recreate the user
    (on Windows: `wsl --unregister pairing` and re-run the installer).
- **Your home must not be readable by other users.** The `pairing` user is
  kept out of your files by normal file permissions. The installer warns if
  your home directory is readable by others, but doesn't change it.
- **The server-key pin only protects what it was checked against.** It
  stops anyone between *you* and the relay from impersonating it — but if
  the key was captured through an already-compromised path, you've pinned
  the attacker. Hence the second check in
  [Setting up the relay](relay.md#setting-it-up).
- **`deploy.sh` hasn't been independently reviewed** beyond initial setup.
  It downloads a checksummed release and sandboxes `uptermd` with systemd,
  but treat it as a starting point, not an audited artifact. It also
  doesn't harden the server around it (see
  [The relay is the most sensitive part](relay.md#the-relay-is-the-most-sensitive-part)).
- **Passphrase-less keys.**
  - A host's `relay_login_key` has no passphrase so `pair` starts
    non-interactively, and it lives in the `pairing` user's home — assume
    past participants have it, which lets them start sessions on your
    relay. Rotate it if that matters: delete it, re-run the installer, and
    swap the line in `relay_authorized_hosts`.
  - A participant's `upterm_client_key` is equally usable by anyone who
    gets a copy of the file; its line in `team_authorized_keys` is what to
    delete when that happens.
