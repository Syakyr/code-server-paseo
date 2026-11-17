# code-server + Paseo in one image

[`code-server`](https://github.com/coder/code-server) (VS Code in the browser) with the
[`Paseo`](https://github.com/getpaseo/paseo) daemon and the [`pi`](https://github.com/earendil-works/pi)
coding agent installed on top, Paseo started by the image's own startup hook, and
fish + starship as the shell every terminal opens. One container, one `$HOME`, one
glibc.

```
ghcr.io/syakyr/code-server-paseo:latest
```

[![build-image](https://github.com/syakyr/code-server-paseo/actions/workflows/build-image.yml/badge.svg)](https://github.com/syakyr/code-server-paseo/actions/workflows/build-image.yml)
[![watch](https://github.com/syakyr/code-server-paseo/actions/workflows/watch.yml/badge.svg)](https://github.com/syakyr/code-server-paseo/actions/workflows/watch.yml)
![amd64](https://img.shields.io/badge/linux-amd64-brightgreen)
![arm64](https://img.shields.io/badge/linux-arm64-brightgreen)

## Why one image

Running Paseo as a second container next to code-server looks tidy and is a trap on
this stack:

- **The glibc split.** The official `ghcr.io/getpaseo/paseo` image is Debian bookworm
  (glibc 2.36). code-server's image is Ubuntu (glibc 2.43+). A Linuxbrew tree built in
  one cannot be mounted into the other — bottles here need up to `GLIBC_2.39`.
- **The `$HOME` split.** Two containers means two `~/.pi`, two `~/.claude`, two
  `~/.codex`, and a bind-mount surgery conversation about which subtrees are safe to
  share. They are not, in general: `.cache`, `.local`, `.npm` and friends hold
  artifacts compiled for one distro.
- **Coder wants one image.** A workspace template publishes one image; code-server is
  the built-in app and Paseo is a `coder_app` behind Coder's own auth.

So: base = code-server, Paseo installed from npm, one home, one libc.

## Quick start

```bash
docker run -d --name workspace \
  -e PASEO_LISTEN=0.0.0.0:6767 \
  -e PASEO_PASSWORD="$(openssl rand -hex 16)" \
  -p 127.0.0.1:10101:8080 \
  -p 127.0.0.1:10102:6767 \
  -v "$PWD/coder:/home/coder" \
  ghcr.io/syakyr/code-server-paseo:latest
```

code-server on `:10101`, Paseo on `:10102`. See [compose.yml](compose.yml) for a
version with a persistent Linuxbrew tree and your code mounted in.

## Gotchas

**`PASEO_LISTEN` defaults to `127.0.0.1:6767`.** Correct when Paseo is reached from
inside the container (a Coder `coder_app`, `localhost`), wrong for a published port —
you get a container that looks healthy and a connection refused. Set
`PASEO_LISTEN=0.0.0.0:6767` when you publish `6767`, and then set `PASEO_PASSWORD`:
the daemon accepts unauthenticated control connections from anything that can reach
it.

**There is no `npm` in this image, and `node` is code-server's own.** The base image
keeps Node at `/usr/lib/code-server/lib/node` and ships no npm. The build installs
Paseo in a throwaway `node` stage and symlinks `/usr/local/bin/node` at code-server's
binary, so `paseo` resolves its shebang without the image carrying a second runtime.
If you want npm for your own work, install it the way you already do (Linuxbrew, or
`nvm`) — it will land ahead of `/usr/local/bin` on `PATH` and shadow nothing.

**pi is baked in; the other agent CLIs are not.** `pi` comes from the image, pinned
and watched, so a fresh device needs no Linuxbrew tree to run agents. `claude`,
`codex` and friends come from whatever you mount or install — the intended pattern is
a persistent Linuxbrew tree at `/home/linuxbrew/.linuxbrew` (see
[compose.yml](compose.yml)).

If your mounted brew tree also has pi, **it shadows the image one in login shells**:
brew's `shellenv` prepends itself to `PATH`, so `pi` resolves to the brew copy and
you get silent version skew. Uninstall it there (`brew uninstall pi-coding-agent`) and
let the image own it.

**The image runs as root.** The base image ends at `USER 1000` (`coder`), but the
install steps here need root and nothing resets it, so code-server and the Paseo
daemon run as uid 0. That predates this repo's shell setup and is tracked
separately: switching to `USER coder` is a visible change for anyone whose
bind-mounted volumes are already root-owned. Both users' login shells are set to
fish so the terminal is the same either way, and `DOCKER_USER` (which renames
`coder`) keeps the shell it has.

## Shell: fish + starship

A fresh terminal in the workspace is fish with the starship prompt. Four levers make
that true, and `scripts/smoke_test.sh` asserts each one:

| Lever | Where | Why it is needed |
| --- | --- | --- |
| `fish`, `starship` installed | apt, Ubuntu archive | the binaries |
| The login shell of `coder` **and** `root` is `/usr/bin/fish` | `usermod` in the Dockerfile | code-server takes the default terminal from the login shell and lists profiles from `/etc/shells`; both live in the image, so a volume over `$HOME` cannot hide them. Both users because the runtime user is unsettled — see the gotcha below |
| `ENV SHELL=/usr/bin/fish` | the Dockerfile | the base image sets no `SHELL` at all, so anything that resolves a shell from the environment falls back to bash |
| `starship init fish \| source` | `/etc/fish/conf.d/starship.fish` | system-wide drop-in, read before `~/.config/fish/config.fish`, so your own config still gets the last word |
| `terminal.integrated.defaultProfile.linux` | written at first boot by [entrypoint.d/91-fish-default](entrypoint.d/91-fish-default) | the IDE's own setting wins over everything above, so the hook adds it only when absent: a default profile you chose by hand stays in place |

Two things this deliberately does not do:

- **It does not pin fish or starship.** They come from the Ubuntu archive with the
  base image (resolute ships `fish 4.2.1-3.2` and `starship 1.22.1-9ubuntu1` in
  universe), so they move with the distro's channel rather than with a watched
  `ARG`. The alternative — a checksum-verified download from GitHub for one of the
  two, while the other can only come from apt — buys a newer starship and a second
  packaging path.
- **It does not remove bash.** `bash` is still there and still what `#!/bin/bash`
  scripts and `docker exec` invocations get. `$SHELL` is only consulted by things
  that deliberately resolve a user shell: npm runs `/bin/sh`, and the agent CLIs
  invoke bash directly.

To go the other way for one user, set `terminal.integrated.defaultProfile.linux` in
your user settings; the boot hook will leave it alone from then on.

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | newest build from `main`: newest `resolute` code-server base + newest Paseo + newest pi |
| `paseo-<x.y.z>` | newest build of that Paseo version |
| `pi-<x.y.z>` | newest build of that pi version |
| `cs-<digest12>` | newest build on that code-server base digest |
| `paseo-<v>-pi<v>-cs-<digest12>` | the immutable triple — pin this in production |
| `dev`, `dev-<sha>` | branch builds, never published from a PR |

`latest` moves only on builds from the default branch, so rebuilding an older pairing
cannot drag it backwards.

## Environment

| Variable | Default | Notes |
| --- | --- | --- |
| `PASEO_LISTEN` | `127.0.0.1:6767` | `0.0.0.0:6767` when a port is published |
| `PASEO_PASSWORD` | unset | required for anything reachable off loopback |
| `PASEO_WEB_UI_ENABLED` | `true` | the daemon serves the Paseo web UI itself |
| `PASEO_HOSTNAMES` | unset | extra DNS names allowed in the `Host` header |
| `PASEO_HOME` | `$HOME/.paseo` | daemon state; created by the hook if missing |
| `HEALTHCHECK_URL` | derived | override for the health probe |

Any `PASEO_*` daemon setting the official image honours works here too, for the same
reason: the daemon is launched in deployment mode.

## How the daemon gets started

The base image entrypoint runs every executable in `$ENTRYPOINTD` (default
`/entrypoint.d`) before it execs `dumb-init` + code-server
([coder/code-server#5177](https://github.com/coder/code-server/issues/5177)). This
image drops one script there, [entrypoint.d/90-paseo](entrypoint.d/90-paseo). No
supervisor, no `s6`, code-server stays PID 1.

That hook obeys three rules, and all three are load-bearing:

1. **Never block.** code-server starts only after every hook returns, so the daemon
   is backgrounded.
2. **Never exit non-zero.** The base entrypoint runs hooks under `set -eu`, so a
   failing hook aborts the container before code-server starts. Losing Paseo must not
   lose the IDE, so every failure is a warning and `exit 0`.
3. **Use `paseo daemon run`, not `paseo daemon start`.** `start` is a *managed*
   launch and `daemonLaunchEnvironment()` deletes every `DAEMON_SETTING_ENV_KEYS`
   entry from the child environment — `PASEO_LISTEN`, `PASEO_PASSWORD`,
   `PASEO_WEB_UI_ENABLED` would all be ignored and the daemon would sit on its
   default port. `run` is deployment mode and keeps the environment.

`scripts/smoke_test.sh` asserts all three, plus that the health probe actually fails
against a dead endpoint.

A home volume mounted from an earlier container can also arrive holding a
`paseo.pid`. Paseo decides whether that lock is live from the boot id and then the
pid, and a container inherits the host's `/proc/sys/kernel/random/boot_id` rather
than getting its own, so the lock reads as fresh while the pid it names has been
recycled by something unrelated; `daemon run` then reports `already_running` and
exits 0 without binding a port. The hook checks `/proc/<pid>/cmdline` and drops the
lock when that process is not Paseo, and drops a record with no pid at all because
Paseo itself refuses to start over one. A lock whose cmdline it cannot read is left
alone, because a second daemon on a shared home is worse than none.

## Pinning and updates

`Dockerfile` carries all three pins as `ARG`s:

```dockerfile
ARG CODE_SERVER_TAG=resolute
ARG CODE_SERVER_DIGEST=sha256:e63d49...
ARG PASEO_VERSION=0.16.0
ARG PI_VERSION=1.5.2
```

[watch.yml](.github/workflows/watch.yml) runs every 6 hours, resolves the newest
`@getpaseo/cli` and `@earendil-works/pi-coding-agent` releases and the current digest
of `codercom/code-server:resolute`, commits any pin bump, probes GHCR for the pairing
tag, and dispatches a build when the image is missing. Every upstream is part of the
pairing tag, so a bump in any one of them rebuilds rather than looking already built.

fish and starship are not pins and are not in the pairing tag — see
[Shell: fish + starship](#shell-fish--starship). A change to the shell setup lands
with the next build from `main`, which republishes `latest`.

Every published pairing also gets a [GitHub
release](../../releases) named after it, with what moved since the previous one —
whether that was Paseo, the code-server base, or neither. The release list is the
version ledger; `scripts/make_release_notes.sh` renders it and skips a release that
already exists rather than overwriting hand-written notes.

Resolve the same facts locally:

```bash
scripts/resolve_pins.sh --check    # exit 1 when either pin is behind upstream
scripts/resolve_pins.sh --all
```

## Development

```bash
docker build -t csp:local --build-arg PASEO_VERSION=0.16.0 --build-arg PI_VERSION=1.5.2 .
scripts/smoke_test.sh csp:local 0.16.0
```

The smoke test boots the container and checks both HTTP servers answer, the health
probe passes live and fails dead, a non-default `PASEO_LISTEN` is discovered, a
failing Paseo hook does not take code-server down, a stale pid lock from an earlier
container gets dropped rather than silencing the daemon, and fish is the default
shell with starship owning the prompt (including that the boot hook does not
overwrite an explicit default profile).

## License

MIT for this repo's own code — see [LICENSE](LICENSE). The image installs unmodified
upstream software: code-server (MIT), Paseo (Apache-2.0), and fish (Apache-2.0) and
starship (MIT or Apache-2.0) from the Ubuntu archive. The npm licenses are copied at
build time from the trees actually in the image and ship at
`/usr/share/licenses/code-server-paseo/`; see [NOTICE](NOTICE).
