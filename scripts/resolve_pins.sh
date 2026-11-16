#!/usr/bin/env bash
# Resolve the two upstream facts this image pins, from the Dockerfile in this
# repo. Used by .github/workflows/watch.yml and runnable locally.
#
#   scripts/resolve_pins.sh --all             # KEY=VALUE lines for both pins
#   scripts/resolve_pins.sh --paseo-version   # newest @getpaseo/cli release
#   scripts/resolve_pins.sh --cs-digest       # current digest of CODE_SERVER_TAG
#   scripts/resolve_pins.sh --check           # diff upstream vs Dockerfile pins
#
# Exit code 1 when a lookup fails or the registry answers something unexpected;
# there is no "guess and continue" path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"

dockerfile_arg() {
    local key="$1"
    sed -n -E "s|^ARG ${key}=(.*)$|\1|p" "$DOCKERFILE" | head -1
}

CODE_SERVER_IMAGE="$(dockerfile_arg CODE_SERVER_IMAGE)"
CODE_SERVER_TAG="$(dockerfile_arg CODE_SERVER_TAG)"
PASEO_PIN="$(dockerfile_arg PASEO_VERSION)"
CS_DIGEST_PIN="$(dockerfile_arg CODE_SERVER_DIGEST)"
[ -n "$CODE_SERVER_IMAGE" ] || { echo "CODE_SERVER_IMAGE not found in $DOCKERFILE" >&2; exit 1; }
[ -n "$CODE_SERVER_TAG" ] || { echo "CODE_SERVER_TAG not found in $DOCKERFILE" >&2; exit 1; }

http_get() {
    # $1 = url, prints body; fails on anything but 200.
    local body code
    body="$(mktemp)"
    code="$(curl -sS --retry 3 --retry-all-errors -o "$body" -w '%{http_code}' "$1")" || {
        rm -f "$body"; return 1; }
    if [ "$code" != "200" ]; then
        echo "HTTP $code for $1" >&2
        head -c 400 "$body" >&2 || true
        rm -f "$body"; return 1
    fi
    cat "$body"
    rm -f "$body"
}

paseo_version() {
    # dist-tags.latest is what `npm i -g @getpaseo/cli` resolves to, which is
    # exactly what "the latest version" has to mean here.
    http_get "https://registry.npmjs.org/@getpaseo/cli/latest" |
        python3 -c 'import json,sys; v=json.load(sys.stdin).get("version",""); sys.exit("no version in npm response") if not v else print(v)'
}

cs_digest() {
    # The top-level `digest` is the multi-arch image index, which is what a
    # buildx multi-platform build pins to. Per-arch digests are listed under
    # `images[]` and are NOT what we want.
    http_get "https://hub.docker.com/v2/repositories/${CODE_SERVER_IMAGE}/tags/${CODE_SERVER_TAG}" |
        python3 -c 'import json,sys; d=json.load(sys.stdin).get("digest",""); sys.exit("no digest in Docker Hub response") if not d else print(d)'
}

pi_version() {
    # Same rule as paseo: dist-tags.latest is what a plain install resolves to.
    http_get "https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest" |
        python3 -c 'import json,sys; v=json.load(sys.stdin).get("version",""); sys.exit("no version in npm response") if not v else print(v)'
}

case "${1:---all}" in
    --paseo-version) paseo_version ;;
    --pi-version)    pi_version ;;
    --cs-digest)     cs_digest ;;
    --all)
        printf 'PASEO_VERSION=%s\n' "$(paseo_version)"
        printf 'PI_VERSION=%s\n' "$(pi_version)"
        printf 'CODE_SERVER_DIGEST=%s\n' "$(cs_digest)"
        ;;
    --check)
        up_paseo="$(paseo_version)"
        up_pi="$(pi_version)"
        up_digest="$(cs_digest)"
        changed=0
        pin() { sed -n -E "s|^ARG $1=(.*)$|\1|p" "$DOCKERFILE" | head -1; }
        report() { # name upstream pinned
            if [ "$2" = "$3" ]; then
                echo "$1       ${3} (upstream ${2}) unchanged"
            else
                echo "$1       ${3} -> ${2}"
                printf 'yes' > "$TMPDIR_CHANGED"
            fi
        }
        TMPDIR_CHANGED="$(mktemp)"
        report paseo "$(paseo_version)" "$(pin PASEO_VERSION)"
        report pi    "$(pi_version)"    "$(pin PI_VERSION)"
        report base  "$(cs_digest)"     "$(pin CODE_SERVER_DIGEST)"
        [ ! -s "$TMPDIR_CHANGED" ] || changed=1
        rm -f "$TMPDIR_CHANGED"
        exit "$changed"
        ;;
    *)
        echo "usage: $0 [--all|--paseo-version|--pi-version|--cs-digest|--check]" >&2
        exit 2
        ;;
esac
