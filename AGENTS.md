# Repository guidance

## `init.sh` modes

`init.sh` runs standalone and through `emobase`, which sets `EMOBASE_CLI=1`.

- Gate standalone-only hints, especially the closing `Next:` block, on
  `[[ "${EMOBASE_CLI:-}" != "1" ]]`. The CLI prints its own next step.
- Keep the generated `.env` summary lines in both modes; only the follow-up
  instructions are hidden.
- The same convention applies to `emobase-infra` and `emobase-deploy`. When you
  change it here, check both siblings in the same pass.

## Keycloak

- This repository owns the Keycloak container. nginx serves it at `/keycloak`;
  there is no separate host port or DNS name.
- `scripts/create-realm.sh` is also called by `emobase keycloak realm create`.
  Keep its flags in sync with `emobase-cli` (`--create-only`, `--existing-only`,
  `--keep-secret`) and update both repositories in the same change.
- Species stacks consume realms; they never create them from a remote server.

## Proxy headers

The portal nginx forwards `X-Forwarded-Host $forwarded_host`, which prefers an
upstream `X-Forwarded-Host`. That is only safe when the TLS proxy overwrites or
strips client-supplied values. Do not copy this pattern to the species stack:
its `fe` trusts the proxy for the origin, so it must forward `$http_host`
instead.

## Verification

In a scratch copy of the checkout:

```bash
EMOBASE_CLI=1 ./init.sh --yes   # summary only
./init.sh --yes                 # summary plus Next
```

Pass the options this checkout needs (`--infra-dir`, `--local`, and so on).
