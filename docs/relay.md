# Running your own relay

Once per team, by the relay admin. Hosts can't install until this is done:
the installers check that the relay in `relay.conf` is up and presents the
expected server key.

- [Why not `upterm`'s public relay](#why-not-upterms-public-relay)
- [What running your own relay fixes](#what-running-your-own-relay-fixes)
- [The relay is the most sensitive part](#the-relay-is-the-most-sensitive-part)
- [One relay per group that trusts each other](#one-relay-per-group-that-trusts-each-other)
- [Setting it up](#setting-it-up)
- [Letting hosts in](#letting-hosts-in)
- [Checking the server key later](#checking-the-server-key-later)
- [Using the public relay instead](#using-the-public-relay-instead)

## Why not `upterm`'s public relay

`upterm` always goes through a relay server (`uptermd`): the host keeps an
SSH tunnel open to it, and participants connect to the relay, not to the
host. By default that's `uptermd.upterm.dev`, a free public relay run by
`upterm`'s maintainer. It's fine for a quick demo — but know what you're
trusting:

- **The relay sees everything in clear text.** Both connections are
  encrypted, but only up to the relay: `uptermd` decrypts traffic from one
  side and re-encrypts it for the other. It is not end-to-end encrypted,
  so the relay can read everything on screen and everything typed — your
  code, Claude's output, a secret you `cat` or paste.
- **The relay can also type.** It sits in the middle of an interactive
  shell, so whoever controls it can inject keystrokes: run commands on the
  host as the session's user.
- **The relay decides who joins.** The host hands its list of allowed keys
  to the relay, and the relay enforces it. Whoever controls the relay can
  let anyone in.
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

## What running your own relay fixes

- **The relay operator is you.** The relay runs on a server your
  organisation controls, so seeing and typing into sessions is limited to
  people who already have access to that server.
- **Its identity is pinned.** Its server key is in `relay.conf` and
  installed into everyone's `known_hosts`, so an impersonated relay gets a
  hard error instead of a yes/no prompt.
- **Only your hosts can use it.** The relay only accepts the machines in
  `relay_authorized_hosts`; it starts out closed.

## The relay is the most sensitive part

Running your own relay moves the risk, it doesn't remove it: the relay
still decrypts every session, can type into it, and enforces who may join.
Whoever gets into the relay server gets into every session. Treat it
accordingly:

- **Few admins:** only the relay admins need `root` on it; hosts and
  participants never do.
- **Your cloud account** (where the VM runs) with two-factor
  authentication — whoever controls that controls the VM.
- **Admin SSH with keys only**, no password logins.
- **Firewall:** only the relay port (2222) and your admin SSH port open.
- **Keep it patched:** OS security updates, and re-run `deploy.sh` now and
  then for `uptermd` updates.
- **Keep a backup of its server key** (`/etc/uptermd/ssh_host_ed25519_key`),
  so a rebuilt relay keeps the same identity and nobody needs to re-pin.

`deploy.sh` sandboxes `uptermd` itself, but doesn't configure the points
above for you.

## One relay per group that trusts each other

- **One pairing-config means one relay with one `team_authorized_keys`
  list.** Everyone on that list can join *any* session on that relay, as
  long as they get hold of its token — and a token is only an address: it
  leaks through a shared chat channel, a forwarded message, a screenshot.
- **If the people on the list trust each other** (one company, similar
  work), one relay and one pairing-config for all of them is fine, and the
  simplest to run. Outsiders stay out either way.
- **If a group must be kept apart** (customer data with stricter rules,
  another company), give it its own relay and its own pairing-config. That
  also keeps it out of view of the other relay's admins, who can see every
  session on their relay.

## Setting it up

`uptermd` is a single Go binary with one SSH port; any small Linux VM with
a public IP will do (any cloud provider — the cheapest tier is plenty).
`upterm`'s own docs list several ways to deploy it — a Helm chart for
Kubernetes, Fly.io, Heroku, Docker Compose behind Traefik, and a hardened
systemd unit: see
[Deploy Uptermd](https://github.com/owenthereal/upterm#deploy-uptermd).
This repo's [`deploy.sh`](../deploy.sh) is the systemd route, scripted, and
the rest of these docs assume it.

1. **Create your team's pairing-config** first, if you haven't — see
   [Get started](../README.md#1-set-up-for-your-team-once).
2. **Create the VM** and open inbound TCP **2222** (`uptermd`) plus your
   admin SSH port in its firewall. Nothing else needs to be reachable.
   - **Its address:** its public address is what everyone will connect
     to. A DNS name (e.g. `relay.example.com`) is handier than a bare IP:
     if the relay ever moves to another VM (taking its server key along),
     nothing changes for anyone. Whichever you pick, use that same form
     everywhere — `known_hosts` matches the exact name or IP.
   - **Its port:** 2222, not 22, because port 22 is taken by the VM's own
     SSH server, the one admins log in with. Any free port works (443 gets
     through more corporate firewalls), as long as it's the same in three
     places: `deploy.sh --ssh-addr 0.0.0.0:<port>`, the VM's firewall, and
     `RELAY_PORT`.
3. **Deploy** from your machine, over SSH as `root` (or a sudo user, `-u`):
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
4. **Fill in `relay.conf`** in your pairing-config and commit it:
   - `RELAY_HOST`: the relay's address from step 2 — the same one you
     passed to `deploy.sh`.
   - `RELAY_PORT`: `uptermd`'s port, `2222` unless you changed it.
   - `RELAY_SERVER_KEY`: the line `deploy.sh` printed at the end.
5. **Double-check the server key over a different path** before anyone
   relies on it.
   - **Why:** `deploy.sh` printed it over *your* network connection. If
     something on that network intercepts SSH (a corporate proxy, a
     compromised router, a hijacked DNS entry), it could show you its own
     key there and again on every check you make from the same network —
     you'd be comparing the attacker with itself.
   - **Best:** your cloud provider's web console, which doesn't go over
     SSH at all. Open a console on the VM and run
     `ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub`; compare the
     fingerprint with the one `deploy.sh` printed.
   - **Otherwise:** from another network (e.g. your phone's hotspot
     instead of the office network):
     ```
     ssh-keyscan -p 2222 -t ed25519 <relay-host>
     ```
   - **If they don't match:** don't commit it. Something between you and
     the relay is rewriting traffic.

## Letting hosts in

- **When:** a new host's relay login key has been merged into
  `relay_authorized_hosts` (see
  [Let the relay know about the new host](host.md#let-the-relay-know-about-the-new-host)).
- **How:** pull pairing-config and apply the list:
  ```
  ./deploy.sh <relay-host> --hosts-only
  ```
- **What it does:** it only uploads the list and restarts `uptermd`, which
  reads the list once at startup. Lines that aren't valid keys are
  refused before anything is sent: `uptermd` would silently ignore every
  key after one.
- **Mind the restart:** it **drops sessions in progress**, so do it when
  nobody's pairing.
- **Removing a host** works the same way: delete its line, merge, apply.

## Checking the server key later

- **To read it again** (e.g. to confirm a redeploy didn't change it):
  ```
  ssh root@<relay-host> 'ssh-keygen -lf /etc/uptermd/ssh_host_ed25519_key.pub'
  ```
- **If it ever changes on purpose:** update `relay.conf` and have everyone
  re-pin it — hosts by re-running the installer, participants by removing
  the old entry (`join` tells them how). Until then, connections hard-fail
  with `REMOTE HOST IDENTIFICATION HAS CHANGED` — correctly, but
  confusingly if nobody expects it.

## Using the public relay instead

You can point your pairing-config at `upterm`'s public relay,
`uptermd.upterm.dev`, instead of running your own. Nothing to deploy — but
do it knowingly.

### When it can make sense

- **Trying this setup out**, before deciding on a server.
- **A one-off demo** with nothing sensitive on screen.
- **Not** for day-to-day work on real code and credentials: see what you
  give up below.

### What you give up

Everything listed in [Why not the public relay](#why-not-upterms-public-relay)
applies again:

- **A third party can read and type into every session**, and decides who
  may join — your `team_authorized_keys` is only as good as their relay.
- **Anyone can host on it**, so there's no `relay_authorized_hosts`: it
  isn't used.
- **No say over availability**, and its server key can change without
  notice (see [If its key changes](#if-its-key-changes)).

### What still works

- **Participants still aren't you:** sessions still run as the `pairing`
  user, with file transfer off. See [What `pair` does](pair.md).
- **The join list still applies** — enforced by the public relay.
- **The pinned server key still protects** against someone *between you
  and* the public relay pretending to be it.

### The values for `relay.conf`

- **`RELAY_HOST="uptermd.upterm.dev"`** — the public relay's address, and
  `upterm`'s default when no `--server` is given.
- **`RELAY_PORT="22"`** — the public relay listens on the standard SSH
  port (`upterm`'s default is `ssh://uptermd.upterm.dev:22`).
- **`RELAY_SERVER_KEY="ssh-ed25519 AAAA..."`** — the public relay doesn't
  publish its key anywhere official, so you fetch it yourself:
  1. **Fetch it:**
     ```
     ssh-keyscan -t ed25519 uptermd.upterm.dev
     ```
     It prints `uptermd.upterm.dev ssh-ed25519 AAAA...`; the value is
     everything after the host name, `ssh-ed25519 AAAA...`.
  2. **Check it from a second network** (e.g. your phone's hotspot) —
     there's no cloud console to check against here, so two independent
     network paths are the best you can do:
     ```
     ssh-keyscan -t ed25519 uptermd.upterm.dev | ssh-keygen -lf -
     ```
     Both fingerprints must match. For reference, on 2026-09-25 it was
     `SHA256:9ajV8JqMe6jJE/s3TYjb/9xw7T0pfJ2+gADiBIJWDPE` — a hint, not
     proof: if yours differs, find out why before trusting either.
- **`relay_authorized_hosts`** — leave it empty. It's only used by
  `deploy.sh` for your own relay; hosts on the public relay don't need to
  register.

After that, hosts and participants carry on as usual (see
[Get started](../README.md#2-host-sessions)); the installer and `join`
work the same way.

### If its key changes

- **What you'll see:** the installer or `join` stops with a server-key
  mismatch.
- **What to do:** fetch and check the key again as above, update
  `relay.conf`, and have hosts re-run their installer. Participants remove
  the old entry the way `join` tells them.
- **Moving to your own relay later** is the same: new values in
  `relay.conf`, hosts re-run their installer.
