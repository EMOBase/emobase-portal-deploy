# EMOBase Portal deployment

Multi-species deployment stack: **emobase-portal-web** (Astro SSR UI) in front
of **emobase-genomics** (API, workers, JBrowse2, BLAST).
MySQL, Keycloak and Elasticsearch are **not** part of this stack; they run once
per server in [`emobase-infra`](https://github.com/EMOBase/emobase-infra) and
are used by the portal and every species deployment on that server.

A deployment server needs **this repository, `emobase-infra`, Docker** and, for
species sites, `emobase-deploy`.

> **Starting from an empty server?** Follow the complete three-repository
> [deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md).
> It covers infrastructure, the portal plus `emobase-deploy`, and the URL
> hand-off between them. The quick start below is the portal half. Day-2 tasks
> are in [Operations](https://github.com/EMOBase/emobase-docs/blob/main/OPERATIONS.md)
> and backups in [Backups](https://github.com/EMOBase/emobase-docs/blob/main/BACKUP.md).

## Services

| Service | Purpose |
| --- | --- |
| `fe` | Portal web UI (`ghcr.io/emobase/emobase-portal-web`) |
| `genomicsservice` | Genomics API (`ghcr.io/emobase/emobase-genomics`) |
| `genomicsworker-1/2` | Async upload/JBrowse2/BLAST jobs |
| `nginx` | Public entrypoint and reverse proxy |
| `blast` | SequenceServer BLAST UI |
| `setup-jbrowse2-web` | One-shot JBrowse2 web-root initialisation |
| `migrate-genomics-db` / `migrate-genomics-es` | One-shot genomics migrations |

The portal connects to this server's `emobase-infra` over the shared
`emobase-infra` Docker network using the service names `mysql`, `keycloak` and
`elasticsearch`. Keycloak is also reachable at `KEYCLOAK_PUBLIC_URL`.

Elasticsearch is shared with every species stack. The portal writes its indices
under the `EMOBASE_GENOMICS_ELASTICSEARCH__INDEX_PREFIX` (default `genomics`),
so it never touches a species' indices.

The portal serves:

| Path | Backend |
| --- | --- |
| `/` | `fe:8080` |
| `/download/` | `${PUBLIC_DATA_DIR}` on the host |
| `/api/genomicsservice/v1/` | `genomicsservice:8080` |
| `/jbrowse/` | JBrowse2 data volume |
| `/blast/` | `blast:4567` |

## Prerequisites

- Docker Engine 24+ with Compose v2
- Outbound HTTPS access to `ghcr.io`
- A running [`emobase-infra`](https://github.com/EMOBase/emobase-infra) stack with its `.env`
## Quick start (portal)

The local [`emobase-infra`](https://github.com/EMOBase/emobase-infra) must be
running first.

```bash
./init.sh

# The portal owns Keycloak; start it before creating the realm.
docker compose up -d --wait keycloak

../infra/scripts/create-database.sh emobase_genomics
./scripts/create-realm.sh \
  --realm "$(grep '^KEYCLOAK_REALM=' .env | cut -d= -f2-)" \
  --origin "$(grep '^PUBLIC_SERVER=' .env | cut -d= -f2-)" \
  --client-id "$(grep '^KEYCLOAK_CLIENT_ID=' .env | cut -d= -f2-)" \
  --client-secret "$(grep '^KEYCLOAK_CLIENT_SECRET=' .env | cut -d= -f2-)" \
  --coco-username "$(grep '^COCO_USERNAME=' .env | cut -d= -f2-)" \
  --coco-password "$(grep '^COCO_PASSWORD=' .env | cut -d= -f2-)" \
  --keep-password --quiet

docker compose --profile '*' pull
docker compose --profile setup run --rm setup-jbrowse2-web
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --wait
./scripts/smoke-test.sh
```

Use `./init.sh --local` for a same-machine trial.

`setup-jbrowse2-web` downloads the pinned `JBROWSE_DOWNLOAD_URL` release
directly, so it does not depend on the rate-limited GitHub API. Override that
variable in `.env` to upgrade JBrowse2 or use a mirror.

The prompts and flags are in the [`init.sh` reference](INIT.md); realm
ownership and sharing are in
[Realm ownership](https://github.com/EMOBase/emobase-docs/blob/main/REALMS.md).

## Species sites

Species deployments consume this portal for genomics, JBrowse2 and BLAST. The
full order is in the
[deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md);
species-specific settings are in the
[`emobase-deploy` README](https://github.com/EMOBase/emobase-deploy/blob/dev/README.md).

## Images

The two EMOBase images are published to GitHub Container Registry:

| Image | Source repository |
| --- | --- |
| `ghcr.io/emobase/emobase-portal-web` | `EMOBase/emobase-portal-web` |
| `ghcr.io/emobase/emobase-genomics` | `EMOBase/emobase-genomics` |

Both are multi-architecture (`linux/amd64` + `linux/arm64`). The packages are
public, so pulling them needs no registry login. Image tags, pinning and branch
guidance are documented in `.env.example`; pull-request builds are
`linux/amd64` only and are not pushed.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for local image builds and the Apple
Silicon/Rosetta requirement.

## BLAST integration

`blast/links_jbrowse2.rb` adds a **Genome Browser** link to hits from a
`*-genome` nucleotide database. It opens JBrowse2 at the hit coordinates with a
temporary BLAST-hit track; the assembly comes from the database name
(`v2a4-genome` → `v2a4`). Protein/RNA hits and mixed searches get no link.

Databases are built from a release by the genomics workers, written to the
`blast-data` volume, and loaded by restarting the `blast` container. That is why
the workers mount the Docker socket and `BLAST_CONTAINER_NAME` must match the
`blast` service. Check `/blast/searchdata.json` to see what SequenceServer has
loaded; an empty list explains a `502` or empty results.

## Updating the portal

The [deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
covers the update order across repositories. To update this stack:

```bash
git pull
docker compose --profile '*' pull
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --wait
```

Because `compose.yml` uses image tags, a plain `docker compose up -d` will not
re-pull a tag that already exists locally. Use `docker compose pull` first, or
pin an immutable tag and change it explicitly. To roll back, set the previous
tag in `.env` and run the same commands.

## Reset

This destroys the portal containers and volumes, but not the shared MySQL,
Keycloak and Elasticsearch data:

```bash
docker compose --profile '*' down -v
```

Reset the shared databases and `genomics-*` indices separately in
`emobase-infra`; see its README.
