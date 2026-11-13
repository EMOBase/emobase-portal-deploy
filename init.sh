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
# and the emobase-docs deployment guide.

set -eo pipefail

PASSWORD_LENGTH=24
FORCE=false
YES=false
PRINT=false
LOCAL=false
PUBLIC_SERVER=
HTTP_PORT=
INFRA_DIR=

DEFAULT_HTTP_PORT=9080
DEFAULT_INFRA_DIR="../emobase-infra"
DEFAULT_INFRA_NETWORK="emobase-infra"

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

# ask VAR "label" "default"
# Keeps an explicit flag or discovered value; otherwise asks with a default.
# --yes uses the default without prompting. A non-terminal without --yes aborts.
ask() {
  local var="$1" label="$2" default="$3" value
  [[ -n "${!var:-}" ]] && return 0
  if [[ "$YES" == true ]]; then
    printf -v "$var" '%s' "$default"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fatal "Cannot ask for ${label}: stdin is not a terminal. Pass --yes or the matching option."
  fi
  if [[ -n "$default" ]]; then
    read -rp "${label} [${default}]: " value
  else
    read -rp "${label}: " value
  fi
  printf -v "$var" '%s' "${value:-$default}"
}

# detect_host_ip prints the address used for the default route. It is the
# server's reachable interface address, not necessarily its internet-facing
# address when the host is behind NAT.
detect_host_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
  }')
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) if ($i !~ /^127\./) { print $i; exit }
    }')
  fi
  if [[ -z "$ip" ]] && command -v ipconfig >/dev/null 2>&1; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  fi
  printf '%s\n' "$ip"
}

is_private_ip() {
  [[ "$1" =~ ^10\. ]] || [[ "$1" =~ ^192\.168\. ]] || \
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]
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
  echo "Without options, asks each value in order and shows its default."
  echo "  --public-server    Public URL of the portal (default: http://localhost:<http-port>)"
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
ask HTTP_PORT "🔌 Host port for nginx" "$DEFAULT_HTTP_PORT"
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( 10#$HTTP_PORT >= 1 && 10#$HTTP_PORT <= 65535 )) \
  || fatal "HTTP_PORT must be a number between 1 and 65535"

default_public="http://localhost:${HTTP_PORT}"
if [[ "$LOCAL" != true ]]; then
  host_ip=$(detect_host_ip)
  if [[ -n "$host_ip" ]]; then
    default_public="http://${host_ip}:${HTTP_PORT}"
    if [[ -z "$PUBLIC_SERVER" ]] && is_private_ip "$host_ip"; then
      >&2 echo "⚠️  Detected host address ${host_ip}; use the public IP or domain if this server is behind NAT."
    fi
  fi
fi
if [[ "$LOCAL" == true ]] && [[ -z "$PUBLIC_SERVER" ]]; then
  PUBLIC_SERVER="http://localhost:${HTTP_PORT}"
  >&2 echo "🏠 Local mode: using ${PUBLIC_SERVER}"
fi
ask PUBLIC_SERVER "🌐 Public URL of the portal" "$default_public"
PUBLIC_SERVER="${PUBLIC_SERVER%/}"
[[ -z "$PUBLIC_SERVER" ]] && fatal "PUBLIC_SERVER cannot be empty"
if [[ "$LOCAL" != true ]] && { [[ "$PUBLIC_SERVER" == *localhost* ]] || [[ "$PUBLIC_SERVER" == *127.0.0.1* ]]; }; then
  >&2 echo "⚠️  PUBLIC_SERVER points at localhost; use a LAN IP or DNS name if another"
  >&2 echo "   machine or container must reach this portal."
fi

# Resolve the shared MySQL/Keycloak secrets from emobase-infra. The deploy
# stacks no longer generate these themselves: one Keycloak client secret and
# one MySQL root password are shared by every stack.
if [[ -z "$INFRA_DIR" ]] && [[ -f "${DEFAULT_INFRA_DIR}/.env" ]]; then
  INFRA_DIR="$DEFAULT_INFRA_DIR"
fi
ask INFRA_DIR "📁 emobase-infra checkout" "$DEFAULT_INFRA_DIR"
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
KEYCLOAK_PUBLIC_URL=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_PUBLIC_URL || true)
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8081/keycloak}"
KEYCLOAK_INTERNAL_URL=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_INTERNAL_URL || true)
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak:8080/keycloak}"
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL%/}"
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL%/}"

if [[ "$KEYCLOAK_PUBLIC_URL" == *localhost* || "$KEYCLOAK_PUBLIC_URL" == *127.0.0.1* ]] \
  && [[ "$PUBLIC_SERVER" != *localhost* && "$PUBLIC_SERVER" != *127.0.0.1* ]]; then
  >&2 echo "⚠️  KEYCLOAK_PUBLIC_URL points at localhost but PUBLIC_SERVER does not."
  >&2 echo "   Set --keycloak-public-url in emobase-infra/init.sh."
fi

INFRA_NETWORK=$(read_env_value "$INFRA_DIR/.env" EMOBASE_INFRA_NETWORK || true)
INFRA_NETWORK="${INFRA_NETWORK:-$DEFAULT_INFRA_NETWORK}"

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

# Keycloak endpoint/realm/client. The portal always uses the realm from
# emobase-infra; species deployments may create dedicated realms.
KEYCLOAK_PUBLIC_URL=${KEYCLOAK_PUBLIC_URL}
KEYCLOAK_INTERNAL_URL=${KEYCLOAK_INTERNAL_URL}
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
>&2 echo "Then deploy the species site with emobase-deploy (see the emobase-docs deployment guide)."
