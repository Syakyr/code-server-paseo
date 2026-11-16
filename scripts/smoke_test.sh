#!/usr/bin/env bash
# Smoke test a code-server-paseo image end to end.
#
# Usage:
#   scripts/smoke_test.sh <image> [paseo_version]
#
# Runs against $DOCKER (default: docker). Covers:
#   1. paseo runs and reports the exact pinned version (not "some" version)
#   2. code-server is still present and reports a version
#   3. the entrypoint hook is in place and executable
#   4. license texts ship inside the image
#   5. the container boots and BOTH servers answer over HTTP
#   6. the built-in healthcheck passes against the live daemon
#   7. the healthcheck FAILS against a dead endpoint (a probe that always
#      returns 0 is worse than no probe)
#   8. the healthcheck discovers a non-default PASEO_LISTEN port on its own
#   9. a Paseo failure does not take code-server down with it
set -euo pipefail

IMAGE="${1:?usage: smoke_test.sh <image> [paseo_version]}"
PASEO_VERSION="${2:-}"
DOCKER="${DOCKER:-docker}"

CID=""
cleanup() { [ -n "$CID" ] && "$DOCKER" rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; [ -z "$CID" ] || "$DOCKER" logs "$CID" 2>&1 | tail -40 >&2; exit 1; }

wait_http() { # url attempts -> sets CODE
    local url="$1" attempts="${2:-40}" i
    CODE="000"
    for i in $(seq 1 "$attempts"); do
        CODE="$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)"
        # code-server redirects to /login (302/307) when auth is on; Paseo
        # answers 200 on /api/health.
        case "$CODE" in 2?? | 301 | 302 | 307) return 0 ;; esac
        sleep 1
    done
    return 1
}

echo "== $IMAGE =="

# 1. exact pinned version ----------------------------------------------------
installed="$("$DOCKER" run --rm --entrypoint paseo "$IMAGE" --version 2>&1 | tail -1)"
echo "  paseo --version: $installed"
if [ -n "$PASEO_VERSION" ]; then
    [ "${installed#v}" = "${PASEO_VERSION}" ] ||
        fail "expected paseo ${PASEO_VERSION}, got ${installed}"
fi
pass "paseo CLI runs and reports the expected version"

# 2. code-server still there -------------------------------------------------
# No `| head -1` here: this script runs with pipefail, and code-server prints
# several lines, so closing the pipe early fails the pipeline with SIGPIPE.
out="$("$DOCKER" run --rm --entrypoint code-server "$IMAGE" --version 2>&1)"
echo "  code-server: ${out%%$'\n'*}"
[ -n "$out" ] || fail "code-server --version produced no output"
pass "code-server runs"

# 3. entrypoint hook ---------------------------------------------------------
"$DOCKER" run --rm --entrypoint sh "$IMAGE" -c \
    'test -x /entrypoint.d/90-paseo && test -x /usr/local/bin/paseo-healthcheck' ||
    fail "/entrypoint.d/90-paseo or the health probe is missing/not executable"
pass "entrypoint hook and health probe present"

# 4. license redistribution --------------------------------------------------
"$DOCKER" run --rm --entrypoint sh "$IMAGE" -c '
    d=/usr/share/licenses/code-server-paseo
    test -s "$d/NOTICE"
    test -s "$d/licenses/paseo-LICENSE"
    test -s "$d/licenses/code-server-LICENSE"' ||
    fail "NOTICE or license texts missing from the image"
pass "redistribution notices present (NOTICE + 2 license texts)"

# 5. both servers answer -----------------------------------------------------
CID="$("$DOCKER" run -d --rm -e PASEO_LISTEN=0.0.0.0:6767 \
    -p 127.0.0.1:18080:8080 -p 127.0.0.1:16767:6767 "$IMAGE")"
wait_http http://127.0.0.1:16767/api/health 60 ||
    fail "paseo /api/health never answered 200 (last: ${CODE})"
pass "paseo daemon serves /api/health"
wait_http http://127.0.0.1:18080/ 60 ||
    fail "code-server never answered (last: ${CODE})"
pass "code-server serves its login/start page"

# 6. healthcheck passes ------------------------------------------------------
"$DOCKER" exec "$CID" /usr/local/bin/paseo-healthcheck ||
    fail "healthcheck failed against a live daemon"
pass "built-in healthcheck passes"

# 7. healthcheck fails on a dead endpoint ------------------------------------
if "$DOCKER" exec -e HEALTHCHECK_URL="http://127.0.0.1:9/api/health" \
        "$CID" /usr/local/bin/paseo-healthcheck >/dev/null 2>&1; then
    fail "healthcheck returned 0 against a dead endpoint"
fi
pass "built-in healthcheck fails against a dead endpoint"

# 8. healthcheck follows PASEO_LISTEN ----------------------------------------
# Regression guard: a probe pinned to :6767 reports a healthy daemon as dead
# the moment the operator moves the port.
"$DOCKER" rm -f "$CID" >/dev/null 2>&1 || true
CID="$("$DOCKER" run -d --rm -e PASEO_LISTEN=0.0.0.0:16767 \
    -p 127.0.0.1:16767:16767 "$IMAGE")"
wait_http http://127.0.0.1:16767/api/health 60 ||
    fail "paseo on the non-default port never came up (last: ${CODE})"
"$DOCKER" exec "$CID" /usr/local/bin/paseo-healthcheck ||
    fail "healthcheck did not discover the non-default PASEO_LISTEN port"
pass "healthcheck discovers a non-default PASEO_LISTEN port"

# 9. a Paseo failure must not kill code-server -------------------------------
# The base entrypoint runs hooks under `set -eu`, so a hook that exits non-zero
# aborts the container before code-server starts. Our hook therefore always
# exits 0. This drives it down that path with an uncreatable PASEO_HOME: the
# daemon cannot start, the IDE must still come up.
"$DOCKER" rm -f "$CID" >/dev/null 2>&1 || true
CID="$("$DOCKER" run -d --rm -e PASEO_LISTEN=0.0.0.0:6767 \
    -e PASEO_HOME=/proc/forbidden \
    -p 127.0.0.1:18080:8080 "$IMAGE")"
wait_http http://127.0.0.1:18080/ 90 ||
    fail "code-server did not start while the paseo hook was failing"
"$DOCKER" logs "$CID" >"${TMPDIR:-/tmp}/csp-smoke.log" 2>&1 || true
grep -q "90-paseo" "${TMPDIR:-/tmp}/csp-smoke.log" ||
    fail "the paseo hook never ran"
pass "code-server survives a paseo hook that cannot start the daemon"

echo "all smoke tests passed"
