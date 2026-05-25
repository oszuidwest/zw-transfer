# zw-transfer

Opinionated, SSO-only Docker Compose deployment of [Pingvin Share X](https://github.com/smp46/pingvin-share-x), pre-configured as **ZuidWest Transfer** (Dutch e-mail templates, password login disabled, registration off, 1 TB share size). Defaults can be overridden via `.env`.

## How to use

### Guided install

On a fresh Debian/Ubuntu server with Docker and Docker Compose, pointing DNS for the public hostname at the host, run as `root`:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/oszuidwest/zw-transfer/main/install.sh)"
```

The installer writes to `/opt/zw-transfer`, prompts for hostname / SMTP / OIDC, starts the stack, and preserves `.env` on re-runs.

### Manual install

```sh
cp .env.example .env
$EDITOR .env
docker compose --env-file .env config
docker compose --env-file .env up -d
```

Fill all blank values in `.env`. For SSO, register an OIDC client with redirect URI `https://<APP_HOSTNAME>/api/oauth/callback/oidc`.

## Conventions

- Working directory: `/opt/zw-transfer/`.
- `docker-compose.yml` is the source of truth: it renders the Pingvin YAML config that Pingvin reads via `CONFIG_FILE` (env vars alone are not enough).
- `.env` carries deployment-specific values (hostname, SMTP, OIDC). To override another default, find its `${VAR:-default}` in `docker-compose.yml` and add `VAR=...` to `.env`. Do not hand-edit `docker-compose.yml`; the installer refreshes it on update.
- Persistent state: `zw-transfer-pingvin-data`, `zw-transfer-caddy-data`, `zw-transfer-caddy-config`.
- Caddy terminates TLS (Let's Encrypt) on 80/443 and proxies to Pingvin on `127.0.0.1:3000`.
- Backend language is Dutch (`general.defaultLanguage`). `patches/email.service.js` (bind-mounted) adds a `{descBlock}` placeholder for the share-recipient e-mail and renders no-expiry shares as `nooit`. It is generated from `patches/email.service.patch` by `scripts/regenerate-email-patch.sh` and refreshed by CI on image bumps.

## Operations

```sh
docker compose ps
docker compose logs -f pingvin
docker compose logs -f caddy
docker compose pull && docker compose up -d
```

Changes to the inline `pingvin_config` in `docker-compose.yml` only take effect on full recreate. Run `docker compose --env-file .env up -d --force-recreate pingvin`; a plain `restart` reuses the previously rendered config file.

Validate before deploying:

```sh
docker compose --env-file .env config
./scripts/validate-pingvin-config.sh .env
```

The validator renders Compose, parses the embedded Pingvin YAML, and checks the type rules that are easy to break: app booleans must stay quoted strings, but `initUser.enabled` / `initUser.isAdmin` must stay real booleans.

## Storage

Uploads land in the `pingvin_data` volume by default. To use S3-compatible storage, set `S3_ENABLED=true` plus the values in `.env.example`. `S3_ENDPOINT` must be a full URL (e.g. `https://s3.eu-central-1.amazonaws.com`). The SQLite database and session state always stay in `pingvin_data`.

Caveats:

- On an S3-backed share, "download all" currently returns HTTP 500 (`Error creating ZIP file`). The upstream owner has acknowledged this and intends to fix it, since the backend already proxies S3. Until a release lands, recipients of S3 shares must download files individually. See [upstream #81](https://github.com/smp46/pingvin-share-x/issues/81).
- Keep the bucket private; Pingvin streams everything through its backend, so public reads would bypass share authorization.
- Enabling S3 does not migrate existing files.
- For Backblaze B2 and some non-AWS providers, set `S3_USE_CHECKSUM=false`.

## Version updates

`.github/workflows/check-pingvin-release.yml` checks for new Pingvin Share X releases, updates the Compose tag, regenerates `patches/email.service.js`, validates the rendered config, and opens a PR.

## Security

- Containers run with `no-new-privileges`; Caddy drops all capabilities except `NET_BIND_SERVICE`.
- The `Docker Security` workflow scans both images with Trivy (Pingvin: OS + app deps; Caddy: OS only) and uploads SARIF to GitHub Security. Findings are surfaced for review and do not block deployments.
- SSO-only is enforced at both layers: app (`OAUTH_DISABLE_PASSWORD=true`, `SHARE_ALLOW_REGISTRATION=false`, `OAUTH_IGNORE_TOTP=true`) and proxy (Caddy redirects `/auth/signIn` to OIDC, blocks OAuth unlink and TOTP endpoints, adds `X-Robots-Tag: noindex`). Do not change password/registration/TOTP defaults without updating the Caddy policy.
- For mail deliverability, keep DKIM on at the provider and use a strict SPF record (e.g. `v=spf1 mx -all`) for the sending domain.
