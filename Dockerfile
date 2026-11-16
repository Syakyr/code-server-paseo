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
ARG PASEO_VERSION=0.16.0

# Paseo is a Node CLI and the code-server image deliberately has no node or npm
# on PATH (it keeps its own at /usr/lib/code-server/lib/node). Install in a
# throwaway node stage, then copy the tree across and point a `node` symlink at
# the node code-server already ships, so the image gains no second runtime.
ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE} AS pack

ARG PASEO_VERSION
# The Paseo server tree pulls an optional onnxruntime native dep that downloads
# at install time. The official Paseo image skips it the same way.
ENV ONNXRUNTIME_NODE_INSTALL=skip

RUN set -eux; \
    test -n "${PASEO_VERSION}" || { echo "PASEO_VERSION build-arg is required"; exit 1; }; \
    npm install -g --prefix /opt/paseo --no-fund --no-audit "@getpaseo/cli@${PASEO_VERSION}"; \
    installed="$(node -p "require('/opt/paseo/lib/node_modules/@getpaseo/cli/package.json').version")"; \
    test "${installed}" = "${PASEO_VERSION}"; \
    npm cache clean --force

ARG CODE_SERVER_IMAGE=codercom/code-server
ARG CODE_SERVER_TAG=resolute
# Digest of the multi-arch index that CODE_SERVER_TAG pointed at when this pin
# was written. Bumped by .github/workflows/watch.yml; a published image tag
# therefore always names one reproducible base.
ARG CODE_SERVER_DIGEST=sha256:e63d49eee8a142443227642faeaf63b61ced12916a611695dbf7250d275afe62
ARG CODE_SERVER_REF=${CODE_SERVER_IMAGE}@${CODE_SERVER_DIGEST}
FROM ${CODE_SERVER_REF}

ARG PASEO_VERSION
USER root

# /opt/paseo is self-contained (npm's bin symlinks are relative), so it lives
# outside code-server's own trees. `node` on PATH is what the `paseo` shebang
# (`/usr/bin/env -S node --disable-warning=DEP0040`) resolves, and code-server's
# bundled node is the runtime the image already ships and runs on.
COPY --from=pack /opt/paseo /opt/paseo
RUN set -eux; \
    test -x /usr/lib/code-server/lib/node; \
    ln -sf /usr/lib/code-server/lib/node /usr/local/bin/node; \
    ln -sf /opt/paseo/bin/paseo /usr/local/bin/paseo; \
    node --version; \
    paseo --version | grep -q "${PASEO_VERSION}"

# License texts come from the trees already in the image rather than vendored
# copies, so they cannot drift from what is actually shipped.
COPY NOTICE /usr/share/licenses/code-server-paseo/NOTICE
COPY entrypoint.d/90-paseo /entrypoint.d/90-paseo
COPY healthcheck /usr/local/bin/paseo-healthcheck
RUN set -eux; \
    dest=/usr/share/licenses/code-server-paseo; \
    mkdir -p "$dest/licenses"; \
    test -s "$dest/NOTICE"; \
    test -s /opt/paseo/lib/node_modules/@getpaseo/cli/LICENSE; \
    cp /opt/paseo/lib/node_modules/@getpaseo/cli/LICENSE "$dest/licenses/paseo-LICENSE"; \
    test -s /usr/lib/code-server/LICENSE; \
    cp /usr/lib/code-server/LICENSE "$dest/licenses/code-server-LICENSE"; \
    chmod 0755 /entrypoint.d/90-paseo /usr/local/bin/paseo-healthcheck; \
    ls -l /entrypoint.d/

# Loopback by default: reachable from inside the workspace (Coder's coder_app,
# localhost) without exposing the daemon. Set PASEO_LISTEN=0.0.0.0:6767 when a
# published container port has to reach it.
ENV PASEO_LISTEN=127.0.0.1:6767 \
    PASEO_WEB_UI_ENABLED=true

HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/paseo-healthcheck"]

# Base image ENTRYPOINT (/usr/bin/entrypoint.sh: fixuid, entrypoint.d hooks,
# then exec dumb-init /usr/bin/code-server) and USER coder are kept as-is.
