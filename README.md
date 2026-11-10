# EMOBase Portal deployment

Multi-species deployment stack: **emobase-portal-web** (Astro SSR UI) in front
of **emobase-genomics** (API, workers, Elasticsearch, JBrowse2, BLAST).
MySQL and Keycloak are **not** part of this stack; they run once in the shared
[`emobase-infra`](../emobase-infra) stack and are used by the portal and every
species deployment.

A deployment server needs **this repository, `emobase-infra`, Docker** and, for
species sites, `emobase-deploy`.

> **Starting from an empty server?** Follow the complete three-repository
> runbook in [DEPLOYMENT.md](DEPLOYMENT.md). It covers infrastructure, the
> portal plus `emobase-deploy`, the URL hand-off between them, TLS, updates and
> backups. The quick start below is the portal half.

## Services

| Service | Purpose |
| --- | --- |
| `fe` | Portal web UI (`ghcr.io/emobase/emobase-portal-web`) |
| `genomicsservice` | Genomics API (`ghcr.io/emobase/emobase-genomics`) |
| `genomicsworker-1/2` | Async upload/JBrowse2/BLAST jobs |
| `nginx` | Public entrypoint and reverse proxy |
| `es` | Elasticsearch for search indices |
| `blast` | SequenceServer BLAST UI |
| `setup-jbrowse2-web` | One-shot JBrowse2 web-root initialisation |
| `migrate-genomics-db` / `migrate-genomics-es` | One-shot genomics migrations |

MySQL and Keycloak are provided by `emobase-infra` and reached over the shared
`emobase-infra` Docker network as `mysql` and `keycloak`. Keycloak is still
served to browsers at `<PUBLIC_SERVER>/ibb/keycloak/`, proxied by this stack's
nginx.

The portal web UI is served at `/`. Genomics, Keycloak, BLAST and JBrowse2 keep
the `/ibb/...` paths that the web UI uses by default:

| Path | Backend |
| --- | --- |
| `/` | `fe:8080` |
| `/download/` | `${PUBLIC_DATA_DIR}` on the host |
| `/ibb/api/genomicsservice/v1/` | `genomicsservice:8080` |
| `/ibb/keycloak/` | `keycloak:8080` |
| `/ibb/jbrowse2/` | JBrowse2 data volume |
| `/ibb/blast/` | `blast:4567` |

## Prerequisites

- Docker Engine 24+ with Compose v2
- Outbound HTTPS access to `ghcr.io`
- A public URL (or host:port) for the portal
- A running [`emobase-infra`](../emobase-infra) stack with its `.env`
- The images are public, so no registry login is normally needed. If the
  packages are private, log in once:

  ```bash
  echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
  ```

  The token needs the `read:packages` scope.

## Quick start (portal)

`compose.yml` contains no `build:` sections. The shared infrastructure must be
running first; its `.env` supplies `MYSQL_ROOT_PASSWORD` and
`KEYCLOAK_CLIENT_SECRET`.

0. Start [`emobase-infra`](../emobase-infra) if it is not running:

   ```bash
   cd ../emobase-infra
   ./init.sh --portal-server https://portal.example.org
   docker compose up -d --wait
   cd ../emobase-portal-deploy
   ```

1. Generate `.env`:

   ```bash
   ./init.sh --public-server https://portal.example.org --http-port 9080
   ```

   The script reads the shared MySQL/Keycloak secrets, realm and client ID from
   `../emobase-infra/.env` automatically (use `--infra-dir` when it is
   elsewhere). The portal always uses the shared realm. It asks for missing
   values and generates the remaining secrets. Review `.env` before continuing,
   especially the image tags. For a local test, leave the defaults:
   `./init.sh --yes`.

2. Pull images (including the one-shot setup/update services):

   ```bash
   docker compose --profile '*' pull
   ```

3. Initialise JBrowse2 and run the database migrations:

   ```bash
   docker compose --profile setup run --rm setup-jbrowse2-web
   docker compose --profile update run --rm migrate-genomics-db
   docker compose --profile update run --rm migrate-genomics-es
   ```

   The migrations write to the shared MySQL instance. They must run after
   `emobase-infra` is healthy. The JBrowse2 setup only uses the shared volume.

4. Start the stack and verify:

   ```bash
   docker compose up -d --wait
   ./scripts/smoke-test.sh
   ```

5. Open `${PUBLIC_SERVER}`. Keycloak admin is at
   `${PUBLIC_SERVER}/ibb/keycloak/admin/` using the `KEYCLOAK_ADMIN` /
   `KEYCLOAK_ADMIN_PASSWORD` from `../emobase-infra/.env`.

The imported realm user (`COCO_USERNAME`) has the `default-roles-ibb` role and
can sign in to the portal and every species site. Its password is temporary;
Keycloak asks for a new password on first login. Create more users from the
Keycloak admin console.

The migrations must run **before the portal web UI is used**. If they are
skipped the API returns `500` because tables such as `versions` do not exist
yet.

`/ibb/blast/` may return `502` until the first release has built BLAST
databases. The smoke test reports that as a warning; set `STRICT_BLAST=1` to
make it fatal.

### Local trial (no domain)

Without DNS or TLS, use `localhost` for the browser URLs. Start the shared
infrastructure first:

```bash
cd ../emobase-infra
./init.sh --local
docker compose up -d --wait
cd ../emobase-portal-deploy
./init.sh --local
```

Then continue with the pull/setup/start steps above and open
`http://localhost:9080`.

When adding a local species site, register its origin with the shared Keycloak:

```bash
cd ../emobase-infra && ./scripts/allow-origin.sh http://localhost:9090
```

The species checkout uses `INTERNAL_*` URLs for calls made from inside its
containers, and `PORTAL_INTERNAL_URL` for the BLAST proxy. Therefore
`localhost` does not have to be reachable from those containers. For the full
local walkthrough, including the species stack, see
[Local setup](DEPLOYMENT.md#local-setup-no-public-server).

## Pairing with emobase-deploy

`emobase-deploy` runs the single-species UI and consumes this portal for
genomics, JBrowse2 and BLAST. Deploy `emobase-infra` and the portal first.

The hand-off is the portal URL, the shared infrastructure values and a few
optional internal URLs:

| Where | Variable | Value |
| --- | --- | --- |
| Infra `.env` | `PORTAL_PUBLIC_SERVER` | **The portal's public URL** |
| Infra `.env` | `KEYCLOAK_REALM` / `KEYCLOAK_CLIENT_ID` | The portal's shared realm/client |
| Portal `.env` | `PUBLIC_SERVER` | The same portal URL |
| Species `.env` | `PORTAL_SERVER` | The same portal URL |
| Species `.env` | `PORTAL_INTERNAL_URL` | Portal origin used by nginx for BLAST |
| Species `.env` | `INTERNAL_*` | Server-side service URLs, if different from public |
| Species `.env` | `PUBLIC_SERVER` | The species site's own public URL |
| Species `.env` | `KEYCLOAK_REALM` | Shared realm, or a dedicated realm (`ibb_<species>`) |
| Species `.env` | `DIRECTUS_DB_DATABASE` | One database per species (e.g. `directus_tcas`) |

With all three repositories cloned into the same parent directory, the species
initialiser copies the shared secrets and portal URL automatically:

```bash
cd ../emobase-deploy
./init.sh \
  --species Tcas \
  --public-server https://tcas.example.org \
  --portal-dir ../emobase-portal-deploy

# Create this species' Directus database in the shared MySQL.
../emobase-infra/scripts/create-database.sh directus_tcas

# Only when this species reuses the portal's shared Keycloak realm.
# A dedicated realm is created by init.sh during the previous step.
../emobase-infra/scripts/allow-origin.sh https://tcas.example.org

docker compose run --rm setup-directus
docker compose up -d --wait
```

`emobase-deploy/init.sh` prompts whether the species should reuse the portal's
shared realm or create a dedicated realm. Use a shared realm when one team
manages every site; use a dedicated realm when each site has its own users and
administrators.

Without `--portal-dir`, `emobase-deploy/init.sh` looks for
`../emobase-portal-deploy/.env` and uses `PORTAL_PUBLIC_SERVER` from
`../emobase-infra/.env` as a fallback. On a separate server, pass
`--portal-server https://portal.example.org` and make the shared secrets
available with `--infra-dir` (or copy them from `emobase-infra/.env`). See
[`../emobase-deploy/README.md`](../emobase-deploy/README.md) and
[DEPLOYMENT.md](DEPLOYMENT.md).

The species nginx proxies `/ibb/blast/` to `PORTAL_INTERNAL_URL` so BLAST
stays same-origin with the species UI. `PORTAL_INTERNAL_URL` defaults to
`PORTAL_SERVER`, which is correct for separate servers. When both stacks share
one Docker host, set it to an internal address such as
`http://host.docker.internal:9080` (or another hostname reachable from the
species stack's default Docker network); the browser-facing `PORTAL_SERVER` can
stay `http://localhost:9080`. SSR API/Keycloak/Directus calls use the matching
`INTERNAL_*` variables and fall back to the public URLs when those are absent.
Keycloak itself is shared. The portal reaches it inside Docker as
`http://keycloak:8080/ibb/keycloak`; species stacks use the portal origin
(`INTERNAL_KEYCLOAK_ISSUER`) so their containers do not join the shared
infra network and collide with other species' service names.

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

## Local development

Start `emobase-infra` first so the external `emobase-infra` Docker network and
the shared MySQL/Keycloak containers exist. Then build from the sibling source
trees instead of pulling images:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published images.

For the one-shot services:

```bash
docker compose -f compose.yml -f compose.local.yml --profile setup run --rm --build setup-jbrowse2-web
docker compose -f compose.yml -f compose.local.yml --profile update run --rm --build migrate-genomics-db
docker compose -f compose.yml -f compose.local.yml --profile update run --rm --build migrate-genomics-es
```

To test a locally built image with the normal compose file, give it the same
name as the published image and set the tag in `.env`:

```bash
docker build -t ghcr.io/emobase/emobase-genomics:test ../emobase-genomics
# .env: EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:test
docker compose up -d
```

### BLAST on Apple Silicon

The SequenceServer image is published for `linux/amd64` only. On an Apple
Silicon host Docker must therefore emulate it, and QEMU's user-mode emulation
deadlocks during SequenceServer startup: the container never binds port 4567
and `/ibb/blast/` returns `502` even when the databases exist.

Enable **Settings → General → Use Virtualization framework** and **Use Rosetta
for x86_64/amd64 emulation**, then restart Docker Desktop. Rosetta runs the
same amd64 image with the stock startup code, so no file in this repository
needs to change. Check that it is active with:

```bash
docker run --rm --platform linux/amd64 alpine sh -c 'ls -l /proc/1/exe'
# expect: /proc/1/exe -> /run/rosetta/rosetta
```

### BLAST result links

`blast/links_jbrowse2.rb` is loaded as a SequenceServer extension and adds a
**Genome Browser** link to hits from a `*-genome` nucleotide database. The link
opens JBrowse2 at the hit coordinates with a temporary BLAST-hit track.

The assembly is derived from the BLAST database name (`v2a4-genome` → `v2a4`),
which is also the JBrowse2 assembly name. Hits from protein or RNA databases
get no link, since JBrowse2 uses the genome assembly as the reference. The link
is only added when a single genome database is selected; mixed searches omit it
so the results page does not run a `blastdbcmd` lookup per hit.

The extension reads assembly track IDs from the shared JBrowse2 config, so the
`blast` service mounts `jbrowse2-data` read-only at `/jbrowse2`.

The link is absolute to `PUBLIC_SERVER`, so it works regardless of which
origin embeds the BLAST page.

## Updating a deployment

Update `emobase-infra` first when its images or realm change, then the portal,
then any species deployment:

```bash
cd ../emobase-infra
git pull && docker compose pull && docker compose up -d --wait
cd ../emobase-portal-deploy
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

## Testing the whole setup

1. Simulate a fresh deployment server: clone `emobase-infra` and this
   repository into a temporary directory (no source trees), initialise and
   start `emobase-infra`, create `.env` with `./init.sh`, then follow “Quick
   start”. This proves the two runtime repositories are self-contained.
2. Run `./scripts/smoke-test.sh` and open the portal web UI in a browser. Sign
   in, then check that `/admin/versions` loads without the `versions` 500.
3. If `emobase-deploy` is part of the test, repeat the checks from
   [DEPLOYMENT.md](DEPLOYMENT.md).

## Notes

- `/var/run/docker.sock` is mounted into the workers because they restart the
  `blast` container after rebuilding databases. The container name is controlled
  by `BLAST_CONTAINER_NAME` and must match the `blast` service.
- BLAST databases are created by the genomics workers (`SETUP_BLAST` jobs) from
  a release and written to the `blast-data` volume. Check
  `/ibb/blast/searchdata.json` to see what the running SequenceServer has
  picked up.
- There is no main-species setting: emobase-genomics serves every assembly in a
  release, and the legacy single-species endpoints default to Tcas internally.
- `/public/versions` is global: it returns READY versions for every species in
  this portal, so a single-species client may list versions from other species
  until species filtering is added to the endpoint.
- To reset the portal containers and volumes (destroys portal data, but not
  the shared MySQL/Keycloak):

  ```bash
  docker compose --profile '*' down -v
  ```

  The shared databases are reset separately in `emobase-infra`; see its
  README.
