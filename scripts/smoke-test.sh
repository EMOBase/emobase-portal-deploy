#!/usr/bin/env bash
# Check that a running deployment answers on its public endpoints.
#
# Usage:
#   ./scripts/smoke-test.sh
#   PUBLIC_SERVER=https://emobase.example.org ./scripts/smoke-test.sh
#
# Reads PUBLIC_SERVER/HTTP_PORT from .env when present.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

BASE="${PUBLIC_SERVER:-http://localhost:${HTTP_PORT:-9091}}"
BASE="${BASE%/}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

fail=0

check() {
  local path="$1" expected="${2:-200}" code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 20 "$BASE$path" || true)"
  if [[ "$code" == "$expected" ]]; then
    printf 'ok   %-3s %s\n' "$code" "$path"
  else
    printf 'FAIL %-3s %s (expected %s)\n' "$code" "$path" "$expected"
    head -c 300 "$tmp" 2>/dev/null || true
    printf '\n'
    fail=1
  fi
}

# BLAST has no databases in a fresh deployment, and SequenceServer does not
# serve the UI until at least one database exists. That is expected before the
# first release, so only warn unless STRICT_BLAST=1 is set.
soft_check() {
  local path="$1" code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 20 "$BASE$path" || true)"
  if [[ "$code" == "200" ]]; then
    printf 'ok   %-3s %s\n' "$code" "$path"
  elif [[ "${STRICT_BLAST:-0}" == "1" ]]; then
    printf 'FAIL %-3s %s (BLAST has no databases yet)\n' "$code" "$path"
    fail=1
  else
    printf 'warn %-3s %s (no BLAST databases yet)\n' "$code" "$path"
  fi
}

echo "Checking $BASE"

# Portal UI and auth
check /
check /admin/versions
check /api/auth/session

# Genomics API (public endpoints, no token needed)
check "/ibb/api/genomicsservice/v1/public/versions?status=READY"
check /ibb/api/genomicsservice/v1/docs

# Keycloak realm
check /ibb/keycloak/realms/ibb

# JBrowse2 static entrypoint, and BLAST (soft until data exists)
check /ibb/jbrowse2/ 200
soft_check /ibb/blast/

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "One or more checks failed. Inspect logs with:"
  echo "  docker compose logs --tail=200 fe genomicsservice nginx keycloak"
  exit 1
fi

echo
echo "All checks passed."
