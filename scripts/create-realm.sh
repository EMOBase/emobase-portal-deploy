#!/usr/bin/env bash
# Create (or update) a Keycloak realm with one browser origin.
#
# Usage:
#   ./scripts/create-realm.sh --realm emobase-tcas --origin https://tcas.example.org
#   ./scripts/create-realm.sh --realm emobase-portal --origin https://portal.example.org \
#     --client-id emobase-portal-client --client-secret ... --coco-password ...
#
# Realms are owned by the portal or species that creates them. Use
# scripts/allow-origin.sh to add another origin to an existing realm.
#
# The script is safe to re-run: it updates the client secret, adds the origin
# if missing, and resets the seed user's temporary password unless
# --keep-password is set.
#
# Requires python3 on the Docker host and a running Keycloak container.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "❌ .env not found. Run ./init.sh first." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 is required to update the Keycloak client." >&2
  exit 1
fi

read_env_value() {
  local file="$1" key="$2" value
  value=$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- | tr -d '\r')
  value=${value#\"}; value=${value%\"}
  value=${value#\'}; value=${value%\'}
  printf '%s\n' "$value"
}

generate_secret_key() {
  local length="${1:-32}" key
  key=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length" || true)
  printf '%s\n' "$key"
}

generate_password() {
  local length="${1:-24}"
  local upper lower digit symbol rest
  upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c1 || true)
  lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c1 || true)
  digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c1 || true)
  symbol=$(LC_ALL=C tr -dc '_=-' </dev/urandom | head -c1 || true)
  rest=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$((length - 4))" || true)
  printf '%s\n' "$upper$lower$digit$symbol$rest" | \
    awk 'BEGIN{srand()} {for(i=1;i<=length;i++) a[i]=substr($0,i,1)}
         END{for(i=1;i<=length;i++){j=int(rand()*length)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp}
             for(i=1;i<=length;i++) printf a[i]; printf "\n"}'
}

usage() {
  echo "Usage: $0 --realm REALM --origin ORIGIN [--client-id ID] [--client-secret SECRET] [--coco-username USER] [--coco-password PASSWORD] [--keep-password] [--quiet]" >&2
}

REALM=
ORIGIN=
CLIENT_ID=emobase-client
CLIENT_SECRET=
COCO_USERNAME=coco
COCO_PASSWORD=
KEEP_PASSWORD=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --realm)
      REALM="$2"
      shift 2
      ;;
    --origin)
      ORIGIN="$2"
      shift 2
      ;;
    --client-id)
      CLIENT_ID="$2"
      shift 2
      ;;
    --client-secret)
      CLIENT_SECRET="$2"
      shift 2
      ;;
    --coco-username)
      COCO_USERNAME="$2"
      shift 2
      ;;
    --coco-password)
      COCO_PASSWORD="$2"
      shift 2
      ;;
    --keep-password)
      KEEP_PASSWORD=true
      shift
      ;;
    --quiet)
      QUIET=true
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

[[ -n "$REALM" ]] || { usage; exit 1; }
[[ -n "$ORIGIN" ]] || { usage; exit 1; }
ORIGIN="${ORIGIN%/}"
[[ "$ORIGIN" =~ ^https?://[^/]+$ ]] || {
  echo "❌ Origin must look like https://tcas.example.org (no path)." >&2
  exit 1
}
[[ "$REALM" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
  echo "❌ Realm names may only contain letters, digits, dot, underscore and hyphen." >&2
  exit 1
}
[[ "$CLIENT_ID" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
  echo "❌ Client IDs may only contain letters, digits, dot, underscore and hyphen." >&2
  exit 1
}

CLIENT_SECRET="${CLIENT_SECRET:-$(generate_secret_key 32)}"
COCO_PASSWORD="${COCO_PASSWORD:-$(generate_password)}"

KEYCLOAK_ADMIN=$(read_env_value .env KEYCLOAK_ADMIN || true)
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD=$(read_env_value .env KEYCLOAK_ADMIN_PASSWORD || true)
[[ -n "$KEYCLOAK_ADMIN_PASSWORD" ]] || {
  echo "❌ .env has no KEYCLOAK_ADMIN_PASSWORD; re-run ./init.sh." >&2
  exit 1
}

kcadm() {
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

if ! docker compose ps --status running --services 2>/dev/null | grep -qx keycloak; then
  echo "❌ The shared Keycloak container is not running. Start it with:" >&2
  echo "   docker compose up -d --wait" >&2
  exit 1
fi

kcadm config credentials \
  --server http://localhost:8080/keycloak \
  --realm master \
  --user "$KEYCLOAK_ADMIN" \
  --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

if kcadm get "realms/$REALM" >/dev/null 2>&1; then
  echo "ℹ️  Realm '$REALM' already exists; updating its client and seed user."
else
  kcadm create realms -s realm="$REALM" -s enabled=true >/dev/null
  echo "✅ Created realm '$REALM'."
fi

client_uuid=$(kcadm get clients -r "$REALM" -q clientId="$CLIENT_ID" \
  --fields id --format csv --noquotes | tail -n1 | tr -d '\r')

if [[ -z "$client_uuid" ]]; then
  kcadm create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s enabled=true \
    -s publicClient=false \
    -s secret="$CLIENT_SECRET" \
    -s standardFlowEnabled=true \
    -s "redirectUris=[\"$ORIGIN/*\"]" \
    -s "webOrigins=[\"$ORIGIN\"]" >/dev/null
  echo "✅ Created client '$CLIENT_ID'."
else
  current=$(kcadm get "clients/$client_uuid" -r "$REALM" --fields redirectUris,webOrigins --format json)
  {
    read -r redirects
    read -r origins
  } < <(printf '%s' "$current" | python3 -c '
import json, sys

data = json.load(sys.stdin)
redirects = data.get("redirectUris") or []
origins = data.get("webOrigins") or []
origin = sys.argv[1].rstrip("/")
redirect = origin + "/*"

if redirect not in redirects:
    redirects.append(redirect)
if origin not in origins:
    origins.append(origin)

print(json.dumps(redirects))
print(json.dumps(origins))
' "$ORIGIN")

  kcadm update "clients/$client_uuid" -r "$REALM" \
    -s "secret=$CLIENT_SECRET" \
    -s "redirectUris=$redirects" \
    -s "webOrigins=$origins" >/dev/null
  echo "✅ Updated client '$CLIENT_ID'."
fi

user_uuid=$(kcadm get users -r "$REALM" -q username="$COCO_USERNAME" \
  --fields id --format csv --noquotes | tail -n1 | tr -d '\r')

user_created=false
if [[ -z "$user_uuid" ]]; then
  kcadm create users -r "$REALM" \
    -s username="$COCO_USERNAME" \
    -s enabled=true \
    -s emailVerified=true >/dev/null
  user_created=true
  echo "✅ Created seed user '$COCO_USERNAME'."
elif [[ "$KEEP_PASSWORD" == true ]]; then
  echo "ℹ️  Seed user '$COCO_USERNAME' already exists; keeping its password."
else
  echo "ℹ️  Seed user '$COCO_USERNAME' already exists; resetting its password."
fi

if [[ "$user_created" == true || "$KEEP_PASSWORD" != true ]]; then
  kcadm set-password -r "$REALM" \
    --username "$COCO_USERNAME" \
    --new-password "$COCO_PASSWORD" \
    --temporary >/dev/null
fi

# User-management permissions for the seed user.
for role in manage-users view-users query-users; do
  kcadm add-roles -r "$REALM" \
    --uusername "$COCO_USERNAME" \
    --cclientid realm-management \
    --rolename "$role" >/dev/null 2>&1 || true
done
kcadm add-roles -r "$REALM" \
  --uusername "$COCO_USERNAME" \
  --rolename "default-roles-$REALM" >/dev/null 2>&1 || true

cat <<EOF

✅ Realm '${REALM}' is ready.
   Origin:        ${ORIGIN}
   Client ID:     ${CLIENT_ID}
EOF
if [[ "$QUIET" != true ]]; then
  echo "   Client secret: ${CLIENT_SECRET}"
  if [[ "$user_created" == true || "$KEEP_PASSWORD" != true ]]; then
    echo "   Seed user:     ${COCO_USERNAME} / ${COCO_PASSWORD} (temporary)"
  else
    echo "   Seed user:     ${COCO_USERNAME} (existing password kept)"
  fi
fi
