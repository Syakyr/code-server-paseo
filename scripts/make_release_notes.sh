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

TAG="" PASEO="" PI="" CS_DIGEST="" CS_SHORT="" CS_VERSION="" IMAGE="" DIGEST=""
SIZE="" PREV="" RUN="" REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2" ;;
        --paseo) PASEO="$2" ;;
        --pi) PI="$2" ;;
        --cs-digest) CS_DIGEST="$2" ;;
        --cs-short) CS_SHORT="$2" ;;
        --cs-version) CS_VERSION="$2" ;;
        --image) IMAGE="$2" ;;
        --digest) DIGEST="$2" ;;
        --size-bytes) SIZE="$2" ;;
        --prev-tag) PREV="$2" ;;
        --run-url) RUN="$2" ;;
        --repo) REPO="$2" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift 2
done

[ -n "$TAG" ] && [ -n "$PASEO" ] && [ -n "$CS_SHORT" ] || {
    echo "--tag, --paseo and --cs-short are required" >&2
    exit 2
}

# A pairing tag is paseo-<version>-cs-<digest12>; pull both halves back out of
# the previous one so the diff is against what was actually published. Anything
# that does not parse — including an API error body leaking through — is treated
# as "no previous release" rather than printed verbatim.
prev_paseo="" prev_short="" prev_pi=""
case "$PREV" in
    paseo-*-pi*-cs-*)
        prev_paseo="$(printf '%s\n' "$PREV" | sed -n -E 's|^paseo-(.+)-pi([^-]+)-cs-([0-9a-f]+)$|\1|p')"
        prev_pi="$(printf '%s\n' "$PREV" | sed -n -E 's|^paseo-.+-pi([^-]+)-cs-([0-9a-f]+)$|\1|p')"
        prev_short="$(printf '%s\n' "$PREV" | sed -n -E 's|^paseo-.+-cs-([0-9a-f]+)$|\1|p')"
        ;;
esac
if [ -z "$prev_paseo" ]; then PREV=""; fi

# Release pages live at /owner/repo/releases/tag/..., so a relative link there
# resolves against /releases and 404s. Absolute URLs only.
REPO="${REPO#https://github.com/}"; REPO="${REPO#/}"
REPO_URL="https://github.com/${REPO:-syakyr/code-server-paseo}"

moved=""
if [ -z "$PREV" ]; then
    moved="first release of this image"
else
    if [ -n "$prev_paseo" ] && [ "$prev_paseo" != "$PASEO" ]; then
        moved="Paseo ${prev_paseo} → ${PASEO}"
    fi
    if [ -n "$prev_pi" ] && [ -n "$PI" ] && [ "$prev_pi" != "$PI" ]; then
        if [ -n "$moved" ]; then moved="${moved}; "; fi
        moved="${moved}pi ${prev_pi} → ${PI}"
    fi
    if [ -n "$prev_short" ] && [ "$prev_short" != "$CS_SHORT" ]; then
        if [ -n "$moved" ]; then moved="${moved}; "; fi
        moved="${moved}code-server base ${prev_short} → ${CS_SHORT}"
    fi
    if [ -z "$moved" ]; then
        moved="nothing upstream — this is a rebuild of ${PREV}"
    fi
fi

# The row carries its own leading newline so an absent size leaves no blank line
# inside the table, which would split it in two.
if [ -n "$SIZE" ] && [ "$SIZE" != "0" ]; then
    size_row="$(printf '\n| Size | %s (compressed manifest sum) |' "$(awk -v b="$SIZE" 'BEGIN{printf "%.0f MB", b/1048576}')")"
else
    size_row=""
fi

cat <<EOF
code-server and the [Paseo](https://github.com/getpaseo/paseo) daemon in one workspace image: one home directory, one glibc, Paseo started by the image's own \`/entrypoint.d\` hook.

**What moved since ${PREV:-nothing}:** ${moved}

**Paseo** ${PASEO}
  npm: https://www.npmjs.com/package/@getpaseo/cli/v/${PASEO}
  Upstream: https://github.com/getpaseo/paseo

**pi** ${PI:-not baked in}
  npm: https://www.npmjs.com/package/@earendil-works/pi-coding-agent/v/${PI:-latest}
  Upstream: https://github.com/earendil-works/pi

**code-server** ${CS_VERSION:-see \`code-server --version\` in the image}
  Upstream: https://github.com/coder/code-server
  Base: \`codercom/code-server@${CS_DIGEST:-sha256:${CS_SHORT}...}\`

## Image

\`\`\`
${IMAGE}
\`\`\`

| | |
| --- | --- |
| Digest | \`${DIGEST:-not captured}\` |${size_row}
| Platforms | \`linux/amd64\`, \`linux/arm64\` |
| Also tagged | \`paseo-${PASEO}\`, \`pi-${PI}\`, \`cs-${CS_SHORT}\`, \`latest\`, \`dev\` |

## Provenance

Built by [this Actions run](${RUN:-.}) from the pins in [\`Dockerfile\`](${REPO_URL}/blob/HEAD/Dockerfile): \`ARG PASEO_VERSION=${PASEO}\`, \`ARG CODE_SERVER_DIGEST=${CS_DIGEST:-sha256:${CS_SHORT}...}\`. The smoke test asserts both servers answer over HTTP, that the health probe fails against a dead endpoint, and that a failing Paseo hook does not take code-server down.

See the [README](${REPO_URL}/blob/HEAD/README.md) for the two gotchas that bite on first run: \`PASEO_LISTEN\` must be \`0.0.0.0:6767\` for a published port, and Paseo's agent CLIs are not in the image.
EOF
