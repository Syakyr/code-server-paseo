#!/usr/bin/env bash
# Render release notes for one published pairing, to stdout.
#
#   scripts/make_release_notes.sh --tag paseo-0.16.0-cs-e63d49eee8a1 \
#       --paseo 0.16.0 --cs-digest sha256:... --cs-short e63d49eee8a1 \
#       --cs-version 4.145.2 --image ghcr.io/syakyr/code-server-paseo:paseo-... \
#       --digest sha256:... --size-bytes 412345678 --prev-tag paseo-0.15.0-cs-... \
#       --run-url https://github.com/.../actions/runs/123
#
# "What moved" is computed against the previous release rather than from memory,
# because the question a reader has is "did Paseo move, or did the base?".
set -euo pipefail

TAG="" PASEO="" CS_DIGEST="" CS_SHORT="" CS_VERSION="" IMAGE="" DIGEST=""
SIZE="" PREV="" RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2" ;;
        --paseo) PASEO="$2" ;;
        --cs-digest) CS_DIGEST="$2" ;;
        --cs-short) CS_SHORT="$2" ;;
        --cs-version) CS_VERSION="$2" ;;
        --image) IMAGE="$2" ;;
        --digest) DIGEST="$2" ;;
        --size-bytes) SIZE="$2" ;;
        --prev-tag) PREV="$2" ;;
        --run-url) RUN="$2" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift 2
done

[ -n "$TAG" ] && [ -n "$PASEO" ] && [ -n "$CS_SHORT" ] || {
    echo "--tag, --paseo and --cs-short are required" >&2
    exit 2
}

# A pairing tag is paseo-<version>-cs-<digest12>; pull both halves back out of
# the previous one so the diff is against what was actually published.
prev_paseo="" prev_short=""
if [ -n "$PREV" ]; then
    prev_paseo="$(printf '%s\n' "$PREV" | sed -n -E 's|^paseo-(.+)-cs-[0-9a-f]+$|\1|p')"
    prev_short="$(printf '%s\n' "$PREV" | sed -n -E 's|^paseo-.+-cs-([0-9a-f]+)$|\1|p')"
fi

moved=""
if [ -z "$PREV" ]; then
    moved="first release of this image"
else
    if [ -n "$prev_paseo" ] && [ "$prev_paseo" != "$PASEO" ]; then
        moved="Paseo ${prev_paseo} → ${PASEO}"
    fi
    if [ -n "$prev_short" ] && [ "$prev_short" != "$CS_SHORT" ]; then
        if [ -n "$moved" ]; then moved="${moved}; "; fi
        moved="${moved}code-server base ${prev_short} → ${CS_SHORT}"
    fi
    if [ -z "$moved" ]; then
        if [ -z "$prev_paseo" ]; then
            moved="previous release ${PREV} does not match the pairing tag format"
        else
            moved="nothing upstream — this is a rebuild of ${PREV}"
        fi
    fi
fi

if [ -n "$SIZE" ] && [ "$SIZE" != "0" ]; then
    size_h="$(awk -v b="$SIZE" 'BEGIN{printf "%.0f MB", b/1048576}')"
else
    size_h="unknown"
fi

cat <<EOF
code-server and the [Paseo](https://github.com/getpaseo/paseo) daemon in one workspace image: one \`$HOME\`, one glibc, Paseo started by the image's own \`/entrypoint.d\` hook.

**What moved since ${PREV:-nothing}:** ${moved}

**Paseo** ${PASEO}
  npm: https://www.npmjs.com/package/@getpaseo/cli/v/${PASEO}
  Upstream: https://github.com/getpaseo/paseo

**code-server** ${CS_VERSION:-see \`code-server --version\` in the image}
  Upstream: https://github.com/coder/code-server
  Base: \`codercom/code-server@${CS_DIGEST:-sha256:${CS_SHORT}...}\`

## Image

\`\`\`
${IMAGE}
\`\`\`

| | |
| --- | --- |
| Digest | \`${DIGEST:-not captured}\` |
| Size | ${size_h} (compressed manifest sum) |
| Platforms | \`linux/amd64\`, \`linux/arm64\` |
| Also tagged | \`paseo-${PASEO}\`, \`cs-${CS_SHORT}\`, \`latest\`, \`dev\` |

## Provenance

Built by [this Actions run](${RUN:-.}) from the pins in [\`Dockerfile\`](blob/master/Dockerfile): \`ARG PASEO_VERSION=${PASEO}\`, \`ARG CODE_SERVER_DIGEST=${CS_DIGEST:-sha256:${CS_SHORT}...}\`. The smoke test asserts both servers answer over HTTP, that the health probe fails against a dead endpoint, and that a failing Paseo hook does not take code-server down.

See the [README](blob/master/README.md) for the two gotchas that bite on first run: \`PASEO_LISTEN\` must be \`0.0.0.0:6767\` for a published port, and Paseo's agent CLIs are not in the image.
EOF
