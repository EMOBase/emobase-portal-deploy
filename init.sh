#!/usr/bin/env bash
# Generate a .env file for the EMOBase portal deployment.
#
# Usage:
#   ./init.sh
#   ./init.sh --public-server https://emobase.example.org
#   ./init.sh --public-server https://emobase.example.org --yes
#   ./init.sh --print > .env
#
# The script only writes .env. Starting the stack is documented in README.md
# and DEPLOYMENT.md.

set -eo pipefail

PASSWORD_LENGTH=24
FORCE=false
YES=false
PRINT=false
LOCAL=false
PUBLIC_SERVER=
HTTP_PORT=
INFRA_DIR=

DEFAULT_PUBLIC_SERVER="http://localhost:9080"
DEFAULT_HTTP_PORT=9080
DEFAULT_INFRA_DIR="../emobase-infra"
DEFAULT_INFRA_NETWORK="emobase-infra"

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

generate_secret_key() {
  length="${1:-32}"
  local key # Needed to avoid pipefail
  key=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length" || true)
  echo "$key"
}

generate_password() {
  length="${1:-$PASSWORD_LENGTH}"

  upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c1 || true)
  lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c1 || true)
  digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c1 || true)
  # "+" is deliberately excluded: emobase-genomics builds the db:migrate DSN
  # in MySQLMigrateDSN, and golang-migrate's MySQL driver url.QueryUnescape()s
  # that password, turning "+" into a space. The API/workers use a different
  # DSN builder and connect fine, but db:migrate fails with "Access denied".
  symbol=$(LC_ALL=C tr -dc '_-=' </dev/urandom | head -c1 || true)

  rest_length=$((length - 4))
  rest=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$rest_length" || true)

  # Shuffle safely using awk (portable)
  printf "%s\n" "$upper$lower$digit$symbol$rest" | \
    awk 'BEGIN{srand()} {for(i=1;i<=length;i++) a[i]=substr($0,i,1)}
         END{for(i=1;i<=length;i++){j=int(rand()*length)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp}
             for(i=1;i<=length;i++) printf a[i]; printf "\n"}'
}

# Read a value from a dotenv file without sourcing it.
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  local value
  value=$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- | tr -d '\r') || return 1
  [[ -n "$value" ]] || return 1
  echo "$value"
}

usage() {
  echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [--public-server URL] [--http-port PORT] [--infra-dir DIR]"
  echo "  --public-server    Public URL of the portal (default: ${DEFAULT_PUBLIC_SERVER})"
  echo "  --http-port        Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
  echo "  --infra-dir        emobase-infra checkout whose .env holds the shared"
  echo "                     MySQL/Keycloak secrets (default: ${DEFAULT_INFRA_DIR} when present)"
  echo "  --local            Use localhost in PUBLIC_SERVER for a local trial"
  echo "  -f, --force        Overwrite an existing .env file"
  echo "  -y, --yes          Use defaults without prompting (secrets are still generated)"
  echo "  -p, --print        Print the generated .env to stdout instead of writing it"
  echo "  -h, --help         Show this help"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --public-server)
      PUBLIC_SERVER="$2"
      shift 2
      ;;
    --http-port)
      HTTP_PORT="$2"
      shift 2
      ;;
    --infra-dir)
      INFRA_DIR="$2"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    --local)
      LOCAL=true
      shift
      ;;
    -p|--print)
      PRINT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ "$PRINT" != true ]]; then
  if [[ -f .env ]] && [[ "$FORCE" != true ]]; then
    echo "⚠️  .env file already exists. Use -f to overwrite."
    exit 1
  fi
fi

# Ask for inputs
if [[ "$LOCAL" == true ]] && [[ -z "$PUBLIC_SERVER" ]]; then
  HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  PUBLIC_SERVER="http://localhost:${HTTP_PORT}"
  >&2 echo "🏠 Local mode: using ${PUBLIC_SERVER}"
fi

if [[ -z "$PUBLIC_SERVER" ]]; then
  if [[ "$YES" == true ]]; then
    PUBLIC_SERVER=${DEFAULT_PUBLIC_SERVER}
  else
    read -rp "🌐 Public URL of the portal [${DEFAULT_PUBLIC_SERVER}]: " PUBLIC_SERVER
    PUBLIC_SERVER="${PUBLIC_SERVER:-${DEFAULT_PUBLIC_SERVER}}"
  fi
fi
PUBLIC_SERVER="${PUBLIC_SERVER%/}"
[[ -z "$PUBLIC_SERVER" ]] && fatal "PUBLIC_SERVER cannot be empty"
if [[ "$LOCAL" != true ]] && { [[ "$PUBLIC_SERVER" == *localhost* ]] || [[ "$PUBLIC_SERVER" == *127.0.0.1* ]]; }; then
  >&2 echo "⚠️  PUBLIC_SERVER points at localhost; use a LAN IP or DNS name if another"
  >&2 echo "   machine or container must reach this portal."
fi

if [[ -z "$HTTP_PORT" ]]; then
  if [[ "$YES" == true ]]; then
    HTTP_PORT=${DEFAULT_HTTP_PORT}
  else
    read -rp "🔌 Host port for nginx [${DEFAULT_HTTP_PORT}]: " HTTP_PORT
    HTTP_PORT="${HTTP_PORT:-${DEFAULT_HTTP_PORT}}"
  fi
fi
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( 10#$HTTP_PORT >= 1 && 10#$HTTP_PORT <= 65535 )) \
  || fatal "HTTP_PORT must be a number between 1 and 65535"

# Resolve the shared MySQL/Keycloak secrets from emobase-infra. The deploy
# stacks no longer generate these themselves: one Keycloak client secret and
# one MySQL root password are shared by every stack.
if [[ -z "$INFRA_DIR" ]] && [[ -f "${DEFAULT_INFRA_DIR}/.env" ]]; then
  INFRA_DIR="$DEFAULT_INFRA_DIR"
fi
if [[ -z "$INFRA_DIR" ]]; then
  fatal "Shared infrastructure .env not found. Run emobase-infra/init.sh first, or pass --infra-dir DIR."
fi
[[ -f "$INFRA_DIR/.env" ]] || fatal "No .env in ${INFRA_DIR}; run emobase-infra/init.sh first."

MYSQL_ROOT_PASSWORD=$(read_env_value "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
[[ -n "$MYSQL_ROOT_PASSWORD" ]] \
  || fatal "${INFRA_DIR}/.env has no MYSQL_ROOT_PASSWORD; re-run emobase-infra/init.sh."
KEYCLOAK_CLIENT_SECRET=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_CLIENT_SECRET || true)
[[ -n "$KEYCLOAK_CLIENT_SECRET" ]] \
  || fatal "${INFRA_DIR}/.env has no KEYCLOAK_CLIENT_SECRET; re-run emobase-infra/init.sh."

KEYCLOAK_REALM=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_REALM || true)
KEYCLOAK_REALM="${KEYCLOAK_REALM:-ibb}"
KEYCLOAK_CLIENT_ID=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_CLIENT_ID || true)
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-ibb-client}"

INFRA_NETWORK=$(read_env_value "$INFRA_DIR/.env" EMOBASE_INFRA_NETWORK || true)
INFRA_NETWORK="${INFRA_NETWORK:-$DEFAULT_INFRA_NETWORK}"

INFRA_PORTAL_SERVER=$(read_env_value "$INFRA_DIR/.env" PORTAL_PUBLIC_SERVER || true)
if [[ -n "$INFRA_PORTAL_SERVER" ]] && [[ "${INFRA_PORTAL_SERVER%/}" != "$PUBLIC_SERVER" ]]; then
  >&2 echo "⚠️  PUBLIC_SERVER (${PUBLIC_SERVER}) does not match"
  >&2 echo "   ${INFRA_DIR}/.env PORTAL_PUBLIC_SERVER (${INFRA_PORTAL_SERVER})."
  >&2 echo "   Keycloak redirects will fail until both values are identical."
fi

>&2 echo "🔗 Using shared MySQL/Keycloak secrets from ${INFRA_DIR}/.env"

ENV_CONTENT="# ── Deployment ──────────────────────────────────────────────────────────────
# Public URL of the portal, including protocol and (if non-standard) port.
# For production, put this behind TLS and set PUBLIC_SERVER to the https URL.
PUBLIC_SERVER=${PUBLIC_SERVER}

# Host port for the nginx entrypoint.
HTTP_PORT=${HTTP_PORT}

# Host directory whose contents are published at \$PUBLIC_SERVER/download/.
# emobase-genomics writes uploads to \$PUBLIC_DATA_DIR/emobase-genomics.
PUBLIC_DATA_DIR=./data/public

# ── Shared infrastructure ───────────────────────────────────────────────────
# MySQL and Keycloak run in the sibling emobase-infra stack. Start it first.
# This stack joins its Docker network; the service names below resolve there.
EMOBASE_INFRA_NETWORK=${INFRA_NETWORK}
EMOBASE_GENOMICS_MYSQL__HOST=mysql
EMOBASE_GENOMICS_MYSQL__PORT=3306
EMOBASE_GENOMICS_MYSQL__USER=root
EMOBASE_GENOMICS_MYSQL__DATABASE=emobase_genomics

# Shared Keycloak realm/client. The portal always uses the realm from
# emobase-infra; species deployments may create dedicated realms.
KEYCLOAK_REALM=${KEYCLOAK_REALM}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID}

# ── EMOBase Genomics ────────────────────────────────────────────────────────
EMOBASE_GENOMICS_ELASTICSEARCH__INDEX_PREFIX=genomics
EMOBASE_GENOMICS_BLAST__DISPLAY_NAME=EMOBase

# Must match the blast service container_name in compose.yml. Workers use it to
# restart SequenceServer after rebuilding BLAST databases.
BLAST_CONTAINER_NAME=emobase-portal-blast

# ── Images ──────────────────────────────────────────────────────────────────
# Published to GitHub Container Registry by GitHub Actions.
#
# \`main\` follows the latest build of the default branch. For a reproducible
# deployment pin an immutable tag instead:
#   * sha-<short>  exact commit build
#   * vX.Y.Z       tagged release
#   * <branch>     latest build of that branch (useful while a feature is
#                  not merged yet)
#
# The multi-species genomics work is merged into the \`dev\` branch. Every push
# to dev publishes :dev automatically. Switch to :main (or a release tag) once
# it is merged into the release branch.
EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:dev
EMOBASE_PORTAL_WEB_IMAGE=ghcr.io/emobase/emobase-portal-web:main

# ── Secrets ─────────────────────────────────────────────────────────────────
# MYSQL_ROOT_PASSWORD and KEYCLOAK_CLIENT_SECRET are copied from
# ${INFRA_DIR}/.env so this stack uses the shared MySQL and Keycloak.
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}

# Generated by init.sh. Keep this file private.
AUTH_SECRET=$(generate_secret_key 48)"

if [[ "$PRINT" == true ]]; then
  echo "$ENV_CONTENT"
  exit 0
fi

printf '%s\n' "$ENV_CONTENT" > .env
chmod 600 .env
mkdir -p data/public/emobase-genomics

>&2 echo "✅ .env file generated successfully"
>&2 echo "   Portal URL: ${PUBLIC_SERVER}"
>&2 echo "   nginx port: ${HTTP_PORT}"
>&2 echo
>&2 echo "Next:"
>&2 echo "  1. Make sure emobase-infra is running (docker compose up -d --wait there)."
>&2 echo "  2. Review .env (image tags, secrets)."
>&2 echo "  3. docker compose --profile '*' pull"
>&2 echo "  4. docker compose --profile setup run --rm setup-jbrowse2-web"
>&2 echo "  5. docker compose --profile update run --rm migrate-genomics-db"
>&2 echo "  6. docker compose --profile update run --rm migrate-genomics-es"
>&2 echo "  7. docker compose up -d --wait"
>&2 echo "  8. ./scripts/smoke-test.sh"
>&2 echo
>&2 echo "Then deploy the species site with emobase-deploy (see DEPLOYMENT.md)."
