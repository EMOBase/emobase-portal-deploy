# EMOBase deployment runbook

This is the full “empty server → working site” procedure for the two deployment
repositories:

| Repository | What it runs | Default host port |
| --- | --- | --- |
| `emobase-portal-deploy` | Portal UI, genomics API/workers, MySQL, Elasticsearch, Keycloak, JBrowse2, BLAST | `9091` |
| `emobase-deploy` | Single-species UI, its own MySQL/Elasticsearch/Keycloak/Directus | `9090` |

Deploy **the portal first**. The species UI reads genomics, JBrowse2 and BLAST
from the portal, so it has nothing useful to show until the portal is running
and a release exists.

Both stacks can run on one server (the current default) or on separate servers.
The only linkage is one URL: the species stack's `PORTAL_SERVER` must equal the
portal stack's `PUBLIC_SERVER`.

No domain or TLS yet? Jump to [Local setup](#local-setup-no-public-server).

```
Browser ──► https://tcas.example.org  (emobase-deploy, :9090)
               │
               ├── /ibb/blast/  proxied to ──► https://portal.example.org/ibb/blast/
               └── JBrowse2/API links ───────► https://portal.example.org/...

Browser ──► https://portal.example.org (emobase-portal-deploy, :9091)
```

## Local setup (no public server)

Use this to try the whole stack on a laptop or desktop before any DNS/TLS
exists. Both sites run over plain HTTP on ports `9090` and `9091`.

The one local-specific rule: **do not use `localhost` for `PORTAL_SERVER`**.
The species nginx runs in a container and proxies BLAST to the portal, so
`localhost` would mean the species container itself. Use the machine's LAN IP
instead. `init.sh --local` detects that IP; open the same address in your
browser.

Prerequisites: Docker Desktop or Docker Engine, both repositories cloned side
by side, and ports `9090`/`9091` free. On Apple Silicon, enable Rosetta for
`linux/amd64` first, or BLAST will not start (see the portal README).

1. Portal:

   ```bash
   cd emobase-portal-deploy
   ./init.sh --local
   ```

   If the detected IP is wrong, pass it explicitly:

   ```bash
   ./init.sh --local --public-server http://192.168.1.10:9091
   ```

   Then start it exactly like a server deployment:

   ```bash
   docker compose --profile '*' pull
   docker compose --profile setup run --rm setup-jbrowse2-web
   docker compose --profile update run --rm migrate-genomics-db
   docker compose --profile update run --rm migrate-genomics-es
   docker compose up -d --wait
   ./scripts/smoke-test.sh
   ```

   `./init.sh --local` prints the chosen URL; open it in a browser.

2. Species site. `--local` also uses the LAN IP, and the portal URL is copied
   from the sibling checkout:

   ```bash
   cd ../emobase-deploy
   ./init.sh --local --species Tcas
   docker compose run --rm setup-directus
   docker compose up -d --wait
   ```

   If the portal checkout is not a sibling, pass its URL explicitly:

   ```bash
   ./init.sh --local --species Tcas --portal-server http://192.168.1.10:9091
   ```

   If the detected species IP is wrong, add
   `--public-server http://<LAN-IP>:9090`.

   Open the species URL printed by `init.sh` (normally
   `http://<LAN-IP>:9090`).

3. Check both sites, sign in with the seeded `coco` user, and confirm that
   JBrowse2/BLAST links point at the portal URL. BLAST returns `502` until the
   first release has built databases.

4. To let a coworker open the same local deployment from another machine on
   the network, use the same LAN IP URLs and allow ports `9090` and `9091` in
   the host firewall. If the machine's IP changes (DHCP), re-run
   `init.sh --local -f` in both checkouts and restart the stacks. Keycloak
   imports its redirect URIs only once, so if login stops working after the IP
   change, reset the local stacks (next step) or update the `ibb-client`
   redirect URIs in the Keycloak admin console.

5. To throw the local data away and start over:

   ```bash
   cd emobase-portal-deploy && docker compose --profile '*' down -v
   cd ../emobase-deploy && docker compose --profile '*' down -v
   ```

## 1. Prepare the server

Requirements:

- Linux server with Docker Engine 24+ and Compose v2
- `git`
- Outbound HTTPS access to `ghcr.io`, Docker Hub and `quay.io`
- Enough RAM/disk for two Elasticsearch instances, two MySQL instances and
  Keycloak. 8 GB RAM is a practical minimum for both stacks on one machine;
  more is better once BLAST databases and releases grow.
- DNS names (or one name plus ports) for both sites
- Ports reachable by the browser: `9091` for the portal and `9090` for the
  species site when using the built-in nginx directly

If you use a TLS reverse proxy in front (recommended), let it listen on 80/443
and keep the two Docker stacks on localhost ports.

Check Docker:

```bash
docker version
docker compose version
```

## 2. Clone both repositories

Use the same parent directory so the helper in `emobase-deploy` can find the
portal's `.env` automatically:

```bash
mkdir -p ~/emobase && cd ~/emobase
git clone https://github.com/EMOBase/emobase-portal-deploy.git
git clone https://github.com/EMOBase/emobase-deploy.git
```

SSH clone URLs work too:

```bash
git clone git@github.com:EMOBase/emobase-portal-deploy.git
git clone git@github.com:EMOBase/emobase-deploy.git
```

The images are public, so no registry login is normally needed. If a package
is private, log in once with a token that has `read:packages`:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

## 3. Choose the two public URLs

Decide the URLs **before** the first start. `PUBLIC_SERVER` is baked into
Keycloak redirect URIs and into links generated by the web UIs; changing it
later requires extra work (see Troubleshooting).

Each stack needs its own origin — a hostname or a port. Both serve their UI at
`/`, so do not put them under path prefixes of the same origin.

Two common layouts:

### A. Direct ports (simple, no TLS)

| Site | URL | Env file |
| --- | --- | --- |
| Portal | `http://SERVER_IP:9091` | `emobase-portal-deploy/.env`: `PUBLIC_SERVER`, `HTTP_PORT=9091` |
| Species | `http://SERVER_IP:9090` | `emobase-deploy/.env`: `PUBLIC_SERVER`, `HTTP_PORT=9090` |

Use the server's LAN/public IP or a DNS name, **not `localhost`**: the species
nginx runs in a container and proxies `/ibb/blast/` to `PORTAL_SERVER`, where
`localhost` would mean the species nginx container itself.

### B. TLS reverse proxy (production)

Example with two DNS names:

| Site | Public URL | Proxy target |
| --- | --- | --- |
| Portal | `https://portal.example.org` | `http://127.0.0.1:9091` |
| Species | `https://tcas.example.org` | `http://127.0.0.1:9090` |

A minimal Caddy configuration:

```caddyfile
portal.example.org {
    reverse_proxy 127.0.0.1:9091
}

tcas.example.org {
    reverse_proxy 127.0.0.1:9090
}
```

With nginx, proxy to the same ports and forward `Host`, `X-Forwarded-Host`,
`X-Forwarded-For` and `X-Forwarded-Proto`; both stacks already honour the
forwarded headers.

The portal URL must be reachable **from the species server**, not just from the
browser, because the species nginx proxies `/ibb/blast/` to it.

## 4. Deploy the portal

```bash
cd ~/emobase/emobase-portal-deploy
./init.sh --public-server https://portal.example.org --http-port 9091 --species Tcas
```

`init.sh` asks for anything not passed as a flag and generates the secrets. It
writes `.env` and prints the next commands. Review `.env` before continuing,
especially:

- `PUBLIC_SERVER` — the exact URL users open
- `HTTP_PORT` — the host port nginx binds
- `EMOBASE_GENOMICS_IMAGE`, `EMOBASE_PORTAL_WEB_IMAGE` — pin a release/SHA tag
  for production instead of a moving branch tag
- `MAIN_SPECIES` and `EMOBASE_GENOMICS_JBROWSE2__GENE_LINK_BASE` — adjust for
  the species you are deploying

Then pull images, initialise JBrowse2, run the migrations and start:

```bash
docker compose --profile '*' pull
docker compose --profile setup run --rm setup-jbrowse2-web
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --wait
```

Verify:

```bash
./scripts/smoke-test.sh
```

Open `PUBLIC_SERVER` in a browser. Keycloak admin is at
`PUBLIC_SERVER/ibb/keycloak/admin/` using `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD` from `.env`.

The migrations must run before the portal UI is used. Without them the API
returns `500` because tables such as `versions` do not exist yet.

`/ibb/blast/` may return `502` at this point. That is expected until the first
release has built BLAST databases; the smoke test only warns about it.

**The portal is now the source of `PORTAL_SERVER`.** Read it from its `.env`:

```bash
grep '^PUBLIC_SERVER=' ~/emobase/emobase-portal-deploy/.env
```

## 5. Deploy the species site

`emobase-deploy` needs two different URLs:

| Variable | Meaning | Value |
| --- | --- | --- |
| `PUBLIC_SERVER` | The URL users open for **this species site** | e.g. `https://tcas.example.org` |
| `PORTAL_SERVER` | The URL of the **portal** (genomics/JBrowse2/BLAST) | the portal's `PUBLIC_SERVER`, e.g. `https://portal.example.org` |

Let `init.sh` copy the portal URL straight from the sibling checkout:

```bash
cd ~/emobase/emobase-deploy
./init.sh \
  --species Tcas \
  --public-server https://tcas.example.org \
  --portal-dir ../emobase-portal-deploy
```

`--portal-dir` reads `PUBLIC_SERVER` from that directory's `.env`. If the
directory is named `../emobase-portal-deploy`, the flag can be omitted:

```bash
./init.sh --species Tcas --public-server https://tcas.example.org
```

On a separate species server, pass the portal URL explicitly instead:

```bash
./init.sh \
  --species Tcas \
  --public-server https://tcas.example.org \
  --portal-server https://portal.example.org
```

Then initialise Directus and start the stack:

```bash
docker compose run --rm setup-directus
docker compose up -d --wait
```

Open the species URL and sign in with the seeded `COCO_USERNAME` /
`COCO_PASSWORD` from `.env`. The password is temporary; Keycloak asks for a new
one on first login.

To add another species later, clone `emobase-deploy` into another directory (or
another server) and repeat only this step with the matching `--species`,
`--public-server` and `--portal-server` / `--portal-dir`. Each species checkout
needs its own `.env`, Directus data and containers. On one Docker host, also
give each stack a distinct `--http-port` and `--container-prefix`.

## 6. Verify the whole setup

On the portal server:

```bash
cd ~/emobase/emobase-portal-deploy
./scripts/smoke-test.sh
```

On the species server:

```bash
cd ~/emobase/emobase-deploy
docker compose ps
curl -I "$(grep '^PUBLIC_SERVER=' .env | cut -d= -f2-)"
```

Manual checks:

1. Portal opens and `/admin/versions` loads (no `versions` 500).
2. Sign-in works on both sites.
3. The species site loads genomics data from the portal.
4. JBrowse2 opens from a genome link.
5. BLAST opens in the species site. It returns `502` until BLAST databases have
   been built from a release.

## 7. Updating a deployment

Update the portal first, then the species UI. The portal may add database
columns or API fields that the species UI expects.

Portal:

```bash
cd ~/emobase/emobase-portal-deploy
git pull
docker compose --profile '*' pull
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --wait
./scripts/smoke-test.sh
```

Species:

```bash
cd ~/emobase/emobase-deploy
git pull
docker compose pull
docker compose up -d --wait
```

A plain `docker compose up -d` does not re-pull a tag that already exists
locally; always `pull` first, or pin an immutable tag and change it explicitly.
To roll back, set the previous image tag in `.env` and repeat the same commands.

## 8. Backup essentials

At minimum back up:

- `emobase-portal-deploy/.env` and `emobase-deploy/.env` (secrets)
- `emobase-portal-deploy/data/public/` (version files, assembly images)
- `emobase-deploy/data/`, `emobase-deploy/images/`
- MySQL data from both stacks (or `mysqldump` output)
- Elasticsearch data from both stacks
- Directus uploads (`directus-data` volume)

Example MySQL dump:

```bash
cd ~/emobase/emobase-portal-deploy
docker compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases' \
  > portal-mysql-$(date +%F).sql
```

For Elasticsearch, use the snapshot procedure in
`emobase-deploy/README.md` for the species stack. The portal's Elasticsearch is
not exposed on a host port; snapshot it from inside the compose network or back
up the `es-data` volume.

## 9. Separate servers later

A species deployment does not have to live beside the portal:

1. On the portal server, finish steps 1–4 and note the public URL.
2. On the new species server, clone only `emobase-deploy` (and Docker).
3. Run `init.sh` with `--portal-server https://portal.example.org`.
4. Make sure the species server can reach the portal:

   ```bash
   curl -fsS https://portal.example.org/ibb/api/genomicsservice/v1/public/versions?status=READY >/dev/null
   ```

5. Open only the species site to users. The portal URL still needs to be
   reachable from browsers for JBrowse2, and from the species server for the
   BLAST proxy.

The reverse direction is **not** supported: the portal does not call the
species stack. The species stack only consumes the portal.

## 10. Troubleshooting

| Symptom | Check |
| --- | --- |
| `502` on the portal | `docker compose ps` and `docker compose logs --tail=200 fe genomicsservice keycloak` |
| Login redirect loop | `PUBLIC_SERVER` must exactly match the browser URL (scheme, host, port) |
| Species site has no data | Portal needs a READY release; species `.env` `PORTAL_SERVER` must match the portal URL |
| BLAST `502` | Expected until a release has built BLAST databases; check `/ibb/blast/searchdata.json` |
| JBrowse2 empty | The release's JBrowse2 jobs must have completed; check worker logs |
| `port is already allocated` | Change `HTTP_PORT` (and `PUBLIC_SERVER` if it contains the port) |
| Image pull denied | `docker login ghcr.io` with `read:packages`; or make the package public |
| Directus not initialised | Re-run `docker compose run --rm setup-directus` |
| Portal API `500` after first start | Migrations were skipped; run both `migrate-genomics-*` services |
| Changed `PUBLIC_SERVER` after first start | Update the Keycloak client redirect URIs in the admin console, or reset the stack |

Changing `PUBLIC_SERVER` after the first start is not automatic for Keycloak:
the realm is imported once, including its redirect URIs. For a throwaway
deployment the cleanest fix is to reset and start over:

```bash
docker compose --profile '*' down -v   # destroys all data
```

Only do that if you can lose the data.

## Deployment checklist

- [ ] Docker + Compose available
- [ ] Both repositories cloned into the same parent directory (or portal URL
      noted for a separate server)
- [ ] Portal `.env` reviewed; `PUBLIC_SERVER` is final; secrets generated
- [ ] Portal images pulled
- [ ] Portal JBrowse2 setup and both migrations completed
- [ ] Portal stack up; smoke test passes
- [ ] Species `.env` has `PUBLIC_SERVER` = species URL
- [ ] Species `.env` has `PORTAL_SERVER` = portal `PUBLIC_SERVER`
- [ ] Directus setup completed
- [ ] Species stack up; both sites open in a browser
- [ ] BLAST/JBrowse2 verified after the first release
- [ ] `.env` files and data backed up
