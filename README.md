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
- A public URL (or host:port) for the portal
- A running [`emobase-infra`](https://github.com/EMOBase/emobase-infra) stack with its `.env`
- The images are public, so no registry login is normally needed. If the
  packages are private, log in once:

  ```bash
  echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
  ```

  The token needs the `read:packages` scope.

## Quick start (portal)

The local [`emobase-infra`](https://github.com/EMOBase/emobase-infra) must be
running first.

```bash
./init.sh

../infra/scripts/create-database.sh emobase_genomics
../infra/scripts/create-realm.sh \
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

- [`init.sh` reference](INIT.md)
- [Local development](DEVELOPMENT.md)
- [BLAST](BLAST.md)
- [Deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
- [Operations](https://github.com/EMOBase/emobase-docs/blob/main/OPERATIONS.md)
- [Realm ownership](https://github.com/EMOBase/emobase-docs/blob/main/REALMS.md)

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

Both are multi-architecture (`linux/amd64` + `linux/arm64`). Image tags,
pinning and branch guidance are documented in `.env.example`; pull-request
builds are `linux/amd64` only and are not pushed.

### One-time package visibility

A package created by `GITHUB_TOKEN` is private by default. If anonymous pulls
should work, open **GitHub → the repository/org → Packages → the package →
Package settings → Change visibility → Public** once per package.

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

## Notes

- There is no main-species setting: emobase-genomics serves every assembly in a
  release, and the legacy single-species endpoints default to Tcas internally.
- `/public/versions` is global: it returns READY versions for every species in
  this portal, so a single-species client may list versions from other species
  until species filtering is added to the endpoint.
- To reset the portal containers and volumes (destroys portal data, but not
  the shared MySQL/Keycloak/Elasticsearch data):

  ```bash
  docker compose --profile '*' down -v
  ```

  The shared databases and `genomics-*` indices are not removed; reset them
  separately in `emobase-infra`; see its README.
