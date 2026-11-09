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

DEFAULT_PUBLIC_SERVER="http://localhost:9080"
DEFAULT_HTTP_PORT=9080

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

generate_secret_key() {
  length="${1:-32}"
  local key # Needed to avoid pipefail
  key=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length")
  echo "$key"
}

generate_password() {
  length="${1:-$PASSWORD_LENGTH}"

  upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c1)
  lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c1)
  digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c1)
  # "+" is deliberately excluded: emobase-genomics builds the db:migrate DSN
  # in MySQLMigrateDSN, and golang-migrate's MySQL driver url.QueryUnescape()s
  # that password, turning "+" into a space. The API/workers use a different
  # DSN builder and connect fine, but db:migrate fails with "Access denied".
  symbol=$(LC_ALL=C tr -dc '_-=' </dev/urandom | head -c1)

  rest_length=$((length - 4))
  rest=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$rest_length")

  # Shuffle safely using awk (portable)
  printf "%s\n" "$upper$lower$digit$symbol$rest" | \
    awk 'BEGIN{srand()} {for(i=1;i<=length;i++) a[i]=substr($0,i,1)}
         END{for(i=1;i<=length;i++){j=int(rand()*length)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp}
             for(i=1;i<=length;i++) printf a[i]; printf "\n"}'
}

usage() {
  echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [--public-server URL] [--http-port PORT]"
  echo "  --public-server    Public URL of the portal (default: ${DEFAULT_PUBLIC_SERVER})"
  echo "  --http-port        Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
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

ENV_CONTENT="# ── Deployment ──────────────────────────────────────────────────────────────
# Public URL of the portal, including protocol and (if non-standard) port.
# For production, put this behind TLS and set PUBLIC_SERVER to the https URL.
PUBLIC_SERVER=${PUBLIC_SERVER}

# Host port for the nginx entrypoint.
HTTP_PORT=${HTTP_PORT}

# Host directory whose contents are published at \$PUBLIC_SERVER/download/.
# emobase-genomics writes uploads to \$PUBLIC_DATA_DIR/emobase-genomics.
PUBLIC_DATA_DIR=./data/public

# ── EMOBase Genomics ────────────────────────────────────────────────────────
EMOBASE_GENOMICS_MYSQL__DATABASE=emobase_genomics
EMOBASE_GENOMICS_MYSQL__USER=root
EMOBASE_GENOMICS_MYSQL__PORT=3306
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
# Generated by init.sh. Keep this file private.
MYSQL_ROOT_PASSWORD=$(generate_password)
AUTH_SECRET=$(generate_secret_key 48)
KEYCLOAK_CLIENT_SECRET=$(generate_secret_key 32)
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=$(generate_password)

# Initial realm user imported by Keycloak. The password is temporary and must
# be changed on first login.
COCO_USERNAME=coco
COCO_PASSWORD=$(generate_password)"

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
>&2 echo "  1. Review .env (image tags, secrets)."
>&2 echo "  2. docker compose --profile '*' pull"
>&2 echo "  3. docker compose --profile setup run --rm setup-jbrowse2-web"
>&2 echo "  4. docker compose --profile update run --rm migrate-genomics-db"
>&2 echo "  5. docker compose --profile update run --rm migrate-genomics-es"
>&2 echo "  6. docker compose up -d --wait"
>&2 echo "  7. ./scripts/smoke-test.sh"
>&2 echo
>&2 echo "Then deploy the species site with emobase-deploy (see DEPLOYMENT.md)."
