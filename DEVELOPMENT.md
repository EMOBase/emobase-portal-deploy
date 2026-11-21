# Local development

Build the stack from local source checkouts instead of pulling the published
images. Start the `infra` checkout first so the external `emobase-infra` Docker
network and the local MySQL/Keycloak/Elasticsearch containers exist.

Set `EMOBASE_PORTAL_WEB_DIR` and `EMOBASE_GENOMICS_DIR` if the source checkouts
are not next to this checkout:

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
docker build -t ghcr.io/emobase/emobase-genomics:test path/to/emobase-genomics
# .env: EMOBASE_GENOMICS_IMAGE=ghcr.io/emobase/emobase-genomics:test
docker compose up -d
```

## BLAST on Apple Silicon

The SequenceServer image is published for `linux/amd64` only. On an Apple
Silicon host Docker must therefore emulate it, and QEMU's user-mode emulation
deadlocks during SequenceServer startup: the container never binds port 4567
and `/blast/` returns `502` even when the databases exist.

Enable **Settings → General → Use Virtualization framework** and **Use Rosetta
for x86_64/amd64 emulation**, then restart Docker Desktop. Rosetta runs the
same amd64 image with the stock startup code, so no file in this repository
needs to change. Check that it is active with:

```bash
docker run --rm --platform linux/amd64 alpine sh -c 'ls -l /proc/1/exe'
# expect: /proc/1/exe -> /run/rosetta/rosetta
```

For BLAST result links and database rebuilds, see [BLAST.md](BLAST.md).
