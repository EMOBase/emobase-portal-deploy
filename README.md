# EMOBase Portal deployment

Multi-species deployment stack: **emobase-portal-web** (Astro SSR UI) in front
of **emobase-genomics** (API, workers, MySQL, Elasticsearch, JBrowse2, BLAST)
and Keycloak for authentication.

Application images are built and published by GitHub Actions, so a deployment
server only needs **this repository plus Docker** — no sibling source trees and
no local builds.

## Services

| Service | Purpose |
| --- | --- |
| `fe` | Portal web UI (`ghcr.io/emobase/emobase-portal-web`) |
| `genomicsservice` | Genomics API (`ghcr.io/emobase/emobase-genomics`) |
| `genomicsworker-1/2` | Async upload/JBrowse2/BLAST jobs |
| `nginx` | Public entrypoint and reverse proxy |
| `keycloak` | OIDC provider (`ibb` realm, `ibb-client`) |
| `mysql` | Genomics + Keycloak database |
| `es` | Elasticsearch for search indices |
| `blast` | SequenceServer BLAST UI |
| `setup-jbrowse2-web` | One-shot JBrowse2 web-root initialisation |
| `migrate-genomics-db` / `migrate-genomics-es` | One-shot genomics migrations |

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
- The images are public, so no registry login is normally needed. If the
  packages are private, log in once:

  ```bash
  echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
  ```

  The token needs the `read:packages` scope.

## First start (deployment server)

Only this repository is needed. `compose.yml` contains no `build:` sections.

1. Create the environment file and set strong secrets:

   ```bash
   cp .env.example .env
   # edit .env: PUBLIC_SERVER, HTTP_PORT, image tags and all secrets
   ```

   Generate secrets with `openssl rand -base64 48`.

2. Pull the images (including the one-shot setup/update services):

   ```bash
   docker compose --profile '*' pull
   ```

3. Initialise JBrowse2 and run the database migrations:

   ```bash
   docker compose --profile setup run --rm setup-jbrowse2-web
   docker compose --profile update run --rm migrate-genomics-db
   docker compose --profile update run --rm migrate-genomics-es
   ```

   These `run` commands start only their dependencies (`mysql`, `es`), wait
   until they are healthy, then exit.

4. Start the stack:

   ```bash
   docker compose up -d
   ```

5. Verify:

   ```bash
   ./scripts/smoke-test.sh
   ```

6. Open `${PUBLIC_SERVER}`. Keycloak admin is at
   `${PUBLIC_SERVER}/ibb/keycloak/` using `KEYCLOAK_ADMIN` /
   `KEYCLOAK_ADMIN_PASSWORD`.

The imported realm user (`COCO_USERNAME`) has the `default-roles-ibb` role and
can sign in to the portal web UI. Its password is temporary; Keycloak asks for
a new password on first login. Create more users from the Keycloak admin
console.

The migrations must run **before the portal web UI is used**. If they are
skipped the API returns `500` because tables such as `versions` do not exist
yet.

## Image pipeline

`emobase-portal-web` and `emobase-genomics` publish multi-architecture images
(`linux/amd64` + `linux/arm64`) to GitHub Container Registry:

| Repository | Image |
| --- | --- |
| `EMOBase/emobase-portal-web` | `ghcr.io/emobase/emobase-portal-web` |
| `EMOBase/emobase-genomics` | `ghcr.io/emobase/emobase-genomics` |

Workflow files:

| Repository | Workflow | Automatic triggers |
| --- | --- | --- |
| `emobase-portal-web` | `.github/workflows/docker-publish.yml` | pushes to `main`/`dev`, `v*` tags, PRs to `main`/`dev` (amd64 only, no push), manual |
| `emobase-genomics` | `.github/workflows/build.yml` | same |

Only the deployment branches (`main`, `dev`) build automatically. To publish an
unmerged feature branch on demand, use **Actions → Run workflow**, or:

```bash
gh workflow run docker-publish.yml --ref <branch>   # emobase-portal-web
gh workflow run build.yml --ref <branch>            # emobase-genomics
```

A manual run publishes `:<branch>` and `:sha-<short>` using the cross-platform
build (amd64 + arm64).

Tags for `main` / `dev` pushes:

| Tag | Meaning |
| --- | --- |
| `main` / `dev` | newest build of that deployment branch |
| `sha-<short>` | immutable build of that commit |
| `latest` | newest build of the default branch (`main`) only |

Tags for a Git tag `v1.2.3`: `v1.2.3`, `1.2.3`, `1.2`, plus `sha-<short>`.

The multi-species genomics work lives on `emobase-genomics` `dev`; every push
to `dev` publishes `:dev` automatically. `.env.example` pins:

```dotenv
EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:dev
EMOBASE_PORTAL_WEB_IMAGE=ghcr.io/emobase/emobase-portal-web:main
```

An unmerged feature branch can still be published on demand (see above) and
used the same way with its branch tag. For production, prefer a release tag or
immutable SHA:

```dotenv
EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:sha-abc1234
EMOBASE_PORTAL_WEB_IMAGE=ghcr.io/emobase/emobase-portal-web:v1.0.0
```

### One-time package visibility

A package created by `GITHUB_TOKEN` is private by default. If anonymous pulls
should work, open **GitHub → the repository/org → Packages → the package →
Package settings → Change visibility → Public** once per package.

## Local development

To build from the sibling source trees instead of pulling images:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published images.

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

For the one-shot services:

```bash
docker compose -f compose.yml -f compose.local.yml --profile setup run --rm --build setup-jbrowse2-web
docker compose -f compose.yml -f compose.local.yml --profile update run --rm --build migrate-genomics-db
```

To test a locally built image with the normal compose file, give it the same
name as the published image and set the tag in `.env`:

```bash
docker build -t ghcr.io/emobase/emobase-genomics:test ../emobase-genomics
# .env: EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:test
docker compose up -d
```

## Updating a deployment

```bash
git pull
docker compose --profile '*' pull
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d
```

Because `compose.yml` uses image tags, a plain `docker compose up -d` will not
re-pull a tag that already exists locally. Use `docker compose pull` first, or
pin an immutable tag and change it explicitly. To roll back, set the previous
tag in `.env` and run the same commands.

## Testing the whole setup

1. Push a branch to `emobase-portal-web` or `emobase-genomics` and watch the
   **Actions** tab. A green run publishes the branch tag.
2. Confirm the image exists for both architectures:

   ```bash
   docker manifest inspect ghcr.io/emobase/emobase-genomics:dev \
     | grep -A2 '"architecture"'
   ```

3. Simulate a fresh deployment server: clone **only** this repository into a
   temporary directory (no `../emobase-*` source directories), create `.env`,
   then follow “First start”. This proves the stack is self-contained.
4. Run `./scripts/smoke-test.sh` and open the portal web UI in a browser. Sign
   in, then check that `/admin/versions` loads without the `versions` 500.

`/ibb/blast/` returns `502` until the first release has built BLAST databases
(SequenceServer does not serve the UI with an empty database directory). The
smoke test reports that as a warning; set `STRICT_BLAST=1` to make it fatal.

## Notes

- `/var/run/docker.sock` is mounted into the workers because they restart the
  `blast` container after rebuilding databases. The container name is controlled
  by `BLAST_CONTAINER_NAME` and must match the `blast` service.
- BLAST databases are created by the genomics workers (`SETUP_BLAST` jobs) from
  a release and written to the `blast-data` volume; there is no separate
  `setup-blast` service. Check `/ibb/blast/searchdata.json` to see what the
  running SequenceServer has picked up.
- `MAIN_SPECIES` is still required by emobase-genomics. It only affects legacy
  single-species endpoints; all assemblies in a release are served in
  multi-species mode.
- `/public/versions` is global: it returns READY versions for every species in
  this portal. A single-species `emobase-deploy` UI pointed at this portal may
  therefore list versions that belong to other species until species filtering
  is added to the endpoint.
- To reset everything (destroys data):

  ```bash
  docker compose --profile '*' down -v
  ```
