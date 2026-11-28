# syntax=docker/dockerfile:1
#
# code-server + Paseo in one workspace image.
#
# Base is code-server's stable-channel tag (`resolute`), pinned by digest below.
# Paseo is installed from npm on top. One image, one $HOME, one glibc — which is
# the whole reason this exists:
#
#   - A separate Paseo container (ghcr.io/getpaseo/paseo, Debian bookworm,
#     glibc 2.36) cannot share a Linuxbrew tree with a code-server container
#     (Ubuntu, glibc 2.43). Bottles here need up to GLIBC_2.39.
#   - One $HOME means one ~/.pi, one ~/.claude, one ~/.codex: agent logins and
#     agent state are shared by definition instead of by bind-mount surgery.
#   - A Coder workspace template wants exactly this: one image, code-server as
#     the built-in app, Paseo as a coder_app behind Coder auth.
#
# The daemon is started by /entrypoint.d/90-paseo, a hook the upstream image
# already runs before it execs code-server (coder/code-server#5177). No
# supervisor is added and code-server stays PID 1 under dumb-init.

# Pinned by .github/workflows/watch.yml to the newest @getpaseo/cli release.
# Global so both stages see one source of truth.
ARG PASEO_VERSION=0.18.1

# pi is baked in so a fresh device gets a working agent without a Linuxbrew
# tree, and so the version is pinned and watched rather than whatever brew
# happens to have. Same package pi-image installs.
ARG PI_VERSION=1.7.0

ARG CODE_SERVER_IMAGE=codercom/code-server
ARG CODE_SERVER_TAG=resolute
# Digest of the multi-arch index that CODE_SERVER_TAG pointed at when this pin
# was written. Bumped by .github/workflows/watch.yml; a published image tag
# therefore always names one reproducible base.
ARG CODE_SERVER_DIGEST=sha256:5afbcc968ff1ca275c7058924ea950d1ede9780734b204b907aa8f229f7c23e3
# Every ARG used in a FROM line must be declared before the first FROM: an ARG
# declared after one is stage-scoped, and a blank base name is the failure.
ARG CODE_SERVER_REF=${CODE_SERVER_IMAGE}@${CODE_SERVER_DIGEST}

# Paseo is a Node CLI and the code-server image deliberately has no node or npm
# on PATH (it keeps its own at /usr/lib/code-server/lib/node). Install in a
# throwaway node stage, then copy the tree across and point a `node` symlink at
# the node code-server already ships, so the image gains no second runtime.
ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE} AS pack

ARG PASEO_VERSION
ARG PI_VERSION
# The Paseo server tree pulls an optional onnxruntime native dep that downloads
# at install time. The official Paseo image skips it the same way.
ENV ONNXRUNTIME_NODE_INSTALL=skip

RUN set -eux; \
    test -n "${PASEO_VERSION}" || { echo "PASEO_VERSION build-arg is required"; exit 1; }; \
    npm install -g --prefix /opt/paseo --no-fund --no-audit "@getpaseo/cli@${PASEO_VERSION}"; \
    installed="$(node -p "require('/opt/paseo/lib/node_modules/@getpaseo/cli/package.json').version")"; \
    test "${installed}" = "${PASEO_VERSION}"; \
    npm cache clean --force

# --ignore-scripts: pi needs no install scripts, and refusing them keeps the
# build reproducible. pi needs node >= 22.19; code-server's bundled node is 24.
RUN set -eux; \
    test -n "${PI_VERSION}" || { echo "PI_VERSION build-arg is required"; exit 1; }; \
    npm install -g --prefix /opt/pi --ignore-scripts --no-fund --no-audit \
      "@earendil-works/pi-coding-agent@${PI_VERSION}"; \
    installed="$(node -p "require('/opt/pi/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version")"; \
    test "${installed}" = "${PI_VERSION}"; \
    npm cache clean --force

FROM ${CODE_SERVER_REF}

ARG PASEO_VERSION
ARG PI_VERSION
USER root

# fish as the workspace shell, starship as its prompt.
#
# Both come from the Ubuntu archive (resolute ships fish 4.2.1-3.2 and starship
# 1.22.1-9ubuntu1 in universe) rather than a vendor installer: one packaging
# path, no download from a third host at build time, and they move with the base
# image's own channel. The cost is stated plainly: neither is a pin in this file,
# so their versions are whatever the archive serves on the build day. That is
# true of any apt layer in any image, and it is the trade for not hand-rolling a
# checksum-verified multi-arch download.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends fish starship; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    fish --version; \
    starship --version | sed -n 1p; \
    # code-server chooses the default terminal from the login shell and lists
    # profiles from /etc/shells, so the passwd entry is the lever that survives
    # a volume mounted over $HOME (see the README quick start).
    #
    # Both users, because the runtime user is not settled: USER root below is
    # what the image actually runs as today (see the note at the end of this
    # file), and coder is the one Coder's DOCKER_USER path and `su - coder`
    # reach. Tracked as follow-up work, not fixed here.
    grep -qx /usr/bin/fish /etc/shells || echo /usr/bin/fish >> /etc/shells; \
    usermod -s /usr/bin/fish coder; \
    usermod -s /usr/bin/fish root; \
    getent passwd coder | cut -d: -f7 | grep -qx /usr/bin/fish; \
    getent passwd root | cut -d: -f7 | grep -qx /usr/bin/fish

# The base image sets no SHELL at all, so anything that resolves a shell from the
# environment — code-server's terminal and tasks, Paseo's terminals — falls back
# to bash. Non-interactive tooling is unaffected: npm runs /bin/sh, and the agent
# CLIs invoke bash directly rather than $SHELL.
ENV SHELL=/usr/bin/fish

# /opt/paseo is self-contained (npm's bin symlinks are relative), so it lives
# outside code-server's own trees. `node` on PATH is what the `paseo` shebang
# (`/usr/bin/env -S node --disable-warning=DEP0040`) resolves, and code-server's
# bundled node is the runtime the image already ships and runs on.
COPY --from=pack /opt/paseo /opt/paseo
COPY --from=pack /opt/pi /opt/pi
RUN set -eux; \
    test -x /usr/lib/code-server/lib/node; \
    ln -sf /usr/lib/code-server/lib/node /usr/local/bin/node; \
    ln -sf /opt/paseo/bin/paseo /usr/local/bin/paseo; \
    ln -sf /opt/pi/bin/pi /usr/local/bin/pi; \
    node --version; \
    paseo --version | grep -q "${PASEO_VERSION}"; \
    pi --version | grep -q "${PI_VERSION}"

# License texts come from the trees already in the image rather than vendored
# copies, so they cannot drift from what is actually shipped.
COPY NOTICE /usr/share/licenses/code-server-paseo/NOTICE
COPY etc/fish/conf.d/starship.fish /etc/fish/conf.d/starship.fish
COPY entrypoint.d/90-paseo /entrypoint.d/90-paseo
COPY entrypoint.d/91-fish-default /entrypoint.d/91-fish-default
COPY healthcheck /usr/local/bin/paseo-healthcheck
RUN set -eux; \
    dest=/usr/share/licenses/code-server-paseo; \
    mkdir -p "$dest/licenses"; \
    test -s "$dest/NOTICE"; \
    test -s /opt/paseo/lib/node_modules/@getpaseo/cli/LICENSE; \
    cp /opt/paseo/lib/node_modules/@getpaseo/cli/LICENSE "$dest/licenses/paseo-LICENSE"; \
    test -s /usr/lib/code-server/LICENSE; \
    cp /usr/lib/code-server/LICENSE "$dest/licenses/code-server-LICENSE"; \
    # The pi npm tarball declares MIT in package.json but ships no license file,
    # so record the declaration rather than inventing a text.
    grep -q '"license": *"MIT"' \
      /opt/pi/lib/node_modules/@earendil-works/pi-coding-agent/package.json; \
    chmod 0755 /entrypoint.d/90-paseo /entrypoint.d/91-fish-default \
      /usr/local/bin/paseo-healthcheck; \
    test -s /etc/fish/conf.d/starship.fish; \
    ls -l /entrypoint.d/

# Loopback by default: reachable from inside the workspace (Coder's coder_app,
# localhost) without exposing the daemon. Set PASEO_LISTEN=0.0.0.0:6767 when a
# published container port has to reach it.
ENV PASEO_LISTEN=127.0.0.1:6767 \
    PASEO_WEB_UI_ENABLED=true

HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/paseo-healthcheck"]

# Base image ENTRYPOINT (/usr/bin/entrypoint.sh: fixuid, entrypoint.d hooks,
# then exec dumb-init /usr/bin/code-server) is kept as-is.
#
# USER is not: the base image ends at USER 1000 (coder), but the install steps
# above need root and nothing resets it, so this image runs its IDE as root. That
# predates the fish setup and changing it is a visible behaviour change for anyone
# whose mounted volumes are already root-owned, so it is left alone here and
# tracked separately rather than slipped into a shell change.
