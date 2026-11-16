# code-server + Paseo in one image

[`code-server`](https://github.com/coder/code-server) (VS Code in the browser) with the
[`Paseo`](https://github.com/getpaseo/paseo) daemon installed on top, started by the
image's own startup hook. One container, one `$HOME`, one glibc.

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

**Paseo's agent CLIs are not in this image.** `pi`, `claude`, `codex` and friends come
from whatever you mount or install. The intended pattern is a persistent Linuxbrew
tree at `/home/linuxbrew/.linuxbrew` (see [compose.yml](compose.yml)), which also
lands them on `PATH` for both code-server and Paseo.

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | newest build from `main`: newest `resolute` code-server base + newest Paseo |
| `paseo-<x.y.z>` | newest build of that Paseo version |
| `cs-<digest12>` | newest build on that code-server base digest |
| `paseo-<x.y.z>-cs-<digest12>` | the immutable pairing — pin this in production |
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
| `PASEO_START_TIMEOUT` | `90` | seconds the startup hook gives `paseo daemon start` |
| `HEALTHCHECK_URL` | derived | override for the health probe |

## How the daemon gets started

The base image entrypoint runs every executable in `$ENTRYPOINTD` (default
`/entrypoint.d`) before it execs `dumb-init` + code-server
([coder/code-server#5177](https://github.com/coder/code-server/issues/5177)). This
image drops one script there, [entrypoint.d/90-paseo](entrypoint.d/90-paseo). No
supervisor, no `s6`, code-server stays PID 1.

That hook obeys two rules, and both are load-bearing:

1. **Never block.** code-server starts only after every hook returns, so
   `paseo daemon start` runs under `timeout`.
2. **Never exit non-zero.** The base entrypoint runs hooks under `set -eu`, so a
   failing hook aborts the container before code-server starts. Losing Paseo must not
   lose the IDE, so every failure is a warning and `exit 0`.

`scripts/smoke_test.sh` asserts both, plus that the health probe actually fails
against a dead endpoint.

## Pinning and updates

`Dockerfile` carries both pins as `ARG`s:

```dockerfile
ARG CODE_SERVER_TAG=resolute
ARG CODE_SERVER_DIGEST=sha256:e63d49...
ARG PASEO_VERSION=0.16.0
```

[watch.yml](.github/workflows/watch.yml) runs every 6 hours, resolves the newest
`@getpaseo/cli` release and the current digest of `codercom/code-server:resolute`,
commits any pin bump, probes GHCR for the pairing tag, and dispatches a build when the
image is missing. Pin bumps are therefore followed by a build automatically; the base
digest is part of the pairing so a code-server-only refresh still rebuilds.

Resolve the same facts locally:

```bash
scripts/resolve_pins.sh --check    # exit 1 when either pin is behind upstream
scripts/resolve_pins.sh --all
```

## Development

```bash
docker build -t csp:local --build-arg PASEO_VERSION=0.16.0 .
scripts/smoke_test.sh csp:local 0.16.0
```

The smoke test boots the container and checks both HTTP servers answer, the health
probe passes live and fails dead, a non-default `PASEO_LISTEN` is discovered, and a
failing Paseo hook does not take code-server down.

## License

MIT for this repo's own code — see [LICENSE](LICENSE). The image installs unmodified
upstream software: code-server (MIT) and Paseo (Apache-2.0). Their texts are copied at
build time from the trees actually in the image and ship at
`/usr/share/licenses/code-server-paseo/`; see [NOTICE](NOTICE).
