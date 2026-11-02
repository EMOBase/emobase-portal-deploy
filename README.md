# EMOBase Portal deployment

Multi-species deployment stack: **emobase-portal** (Astro SSR UI) in front of
**emobase-genomics** (API, workers, MySQL, Elasticsearch, JBrowse2, BLAST) and
Keycloak for authentication.

This is the multi-species successor to `emobase-deploy`. `emobase-deploy` keeps
the single-species `emobase-web` frontend; its `emobase-genomics` services will
be removed once this stack is in place.

## Services

| Service | Purpose |
| --- | --- |
| `portal` | Multi-species UI (`../emobase-portal`) |
| `genomicsservice` | Genomics API (`../emobase-genomics`) |
| `genomicsworker-1/2` | Async upload/JBrowse2/BLAST jobs |
| `nginx` | Public entrypoint and reverse proxy |
| `keycloak` | OIDC provider (`ibb` realm, `ibb-client`) |
| `mysql` | Genomics + Keycloak database |
| `es` | Elasticsearch for search indices |
| `blast` | SequenceServer BLAST UI |
| `setup-jbrowse2-web` | One-shot JBrowse2 web-root initialisation |
| `migrate-genomics-db` / `migrate-genomics-es` | One-shot genomics migrations |

The portal is served at `/`. Genomics, Keycloak, BLAST and JBrowse2 keep the
`/ibb/...` paths that the portal uses by default:

| Path | Backend |
| --- | --- |
| `/` | `portal:8080` |
| `/download/` | `${PUBLIC_DATA_DIR}` on the host |
| `/ibb/api/genomicsservice/v1/` | `genomicsservice:8080` |
| `/ibb/keycloak/` | `keycloak:8080` |
| `/ibb/jbrowse2/` | JBrowse2 data volume |
| `/ibb/blast/` | `blast:4567` |

## First start

1. Create the environment file and set strong secrets:

   ```bash
   cp .env.example .env
   # edit .env: PUBLIC_SERVER, HTTP_PORT and all secrets
   ```

2. Initialise JBrowse2 and run the database migrations:

   ```bash
   docker compose --profile setup run --rm --build setup-jbrowse2-web
   docker compose --profile update run --rm migrate-genomics-db
   docker compose --profile update run --rm migrate-genomics-es
   ```

3. Start the stack:

   ```bash
   docker compose up -d
   ```

4. Open `${PUBLIC_SERVER}`. Keycloak admin is at
   `${PUBLIC_SERVER}/ibb/keycloak/` using `KEYCLOAK_ADMIN` /
   `KEYCLOAK_ADMIN_PASSWORD`.

The imported realm user (`COCO_USERNAME`) has the `default-roles-ibb` role and
can sign in to the portal. Its password is temporary; Keycloak asks for a new
password on first login. Create more users from the Keycloak admin console.

## Updating

```bash
docker compose --profile update run --rm migrate-genomics-db
docker compose --profile update run --rm migrate-genomics-es
docker compose up -d --build
```

## Notes

- `/var/run/docker.sock` is mounted into the workers because they restart the
  `blast` container after rebuilding databases. The container name is controlled
  by `BLAST_CONTAINER_NAME` and must match the `blast` service.
- `MAIN_SPECIES` is still required by emobase-genomics. It only affects legacy
  single-species endpoints; all assemblies in a release are served in
  multi-species mode.
- To reset everything (destroys data):

  ```bash
  docker compose --profile '*' down -v
  ```
