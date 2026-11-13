# Portal `init.sh` reference

`init.sh` generates `emobase-portal-deploy/.env`. The portal owns its Keycloak
realm and its client/seed credentials.

## Prerequisites

- A running `emobase-infra` checkout with `.env`
- Docker Engine 24+ with Compose v2
- `python3` on the host for the Keycloak helper scripts

## Quick run

```bash
./init.sh
```

Every question shows a default. Press Enter to accept it.

## Prompt order

| Question | Default |
| --- | --- |
| nginx host port | `9080` |
| Public portal URL | detected host IPv4, or localhost with `--local` |
| Portal realm | `emobase-portal` |
| Portal client ID | `emobase-portal-client` |
| Seed user | `coco` |

The script generates `KEYCLOAK_CLIENT_SECRET`, `COCO_PASSWORD` and
`AUTH_SECRET`.

The public URL has no path and no trailing slash. Without `--local`, it defaults
to the detected host IPv4 address; enter the public IP or domain if the server
is behind NAT.

## Generated values

The portal `.env` contains:

```dotenv
PUBLIC_SERVER=...
HTTP_PORT=...
KEYCLOAK_REALM=emobase-portal
KEYCLOAK_CLIENT_ID=emobase-portal-client
KEYCLOAK_CLIENT_SECRET=...
COCO_USERNAME=coco
COCO_PASSWORD=...
```

It also contains the MySQL/Keycloak endpoints and `MYSQL_ROOT_PASSWORD` read
from `../emobase-infra/.env`.

## Flags

| Flag | Meaning |
| --- | --- |
| `--local` | Use localhost for the portal URL |
| `--public-server URL` | Public portal URL |
| `--http-port PORT` | Host port for nginx |
| `--infra-dir DIR` | Path to the `emobase-infra` checkout |
| `--keycloak-realm NAME` | Portal realm name |
| `--keycloak-client-id ID` | Portal client ID |
| `--keycloak-client-secret SECRET` | Client secret (generated when omitted) |
| `--coco-username USER` | Seed user name |
| `--coco-password PASSWORD` | Seed password (generated when omitted) |
| `-y`, `--yes` | Accept defaults without prompting |
| `-f`, `--force` | Overwrite an existing `.env` |
| `-p`, `--print` | Print the file instead of writing it |
| `-h`, `--help` | Show help |

## Examples

Local trial:

```bash
./init.sh --local
```

Server with TLS:

```bash
./init.sh \
  --public-server https://portal.example.org \
  --http-port 9080
```

Unattended:

```bash
./init.sh --yes
```

## After init

Create the portal database and realm once infra is healthy:

```bash
../emobase-infra/scripts/create-database.sh emobase_genomics

../emobase-infra/scripts/create-realm.sh \
  --realm "$(grep '^KEYCLOAK_REALM=' .env | cut -d= -f2-)" \
  --origin "$(grep '^PUBLIC_SERVER=' .env | cut -d= -f2-)" \
  --client-id "$(grep '^KEYCLOAK_CLIENT_ID=' .env | cut -d= -f2-)" \
  --client-secret "$(grep '^KEYCLOAK_CLIENT_SECRET=' .env | cut -d= -f2-)" \
  --coco-username "$(grep '^COCO_USERNAME=' .env | cut -d= -f2-)" \
  --coco-password "$(grep '^COCO_PASSWORD=' .env | cut -d= -f2-)" \
  --keep-password --quiet
```

The `emobase` CLI does this automatically during `create portal`, `up` or
`bootstrap` when infra is running.

Then pull images, run JBrowse2 setup and migrations, start, and smoke test:

```bash
docker compose --profile '*' pull
docker compose --profile setup run --rm setup-jbrowse2-web
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --wait
./scripts/smoke-test.sh
```

`setup-jbrowse2-web` installs the release named by `JBROWSE_DOWNLOAD_URL`
directly. The default is pinned, so setup does not query the GitHub API, which
allows only 60 anonymous requests per hour per IP and can fail with HTTP 403 on
shared hosts. Set `JBROWSE_DOWNLOAD_URL` in `.env` to upgrade JBrowse2 or to use
a local mirror.

See [REALMS.md](https://github.com/EMOBase/emobase-docs/blob/main/REALMS.md)
for realm ownership and sharing.
