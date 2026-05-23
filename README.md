# zw-transfer

An opinionated, SSO-only Docker Compose deployment of [Pingvin Share X](https://github.com/smp46/pingvin-share-x), pre-configured as **ZuidWest Transfer** (default branding, Dutch e-mail templates, password login disabled, registration off, 1 TB share size, recipients panel always visible). Supported deployment defaults can be overridden via `.env`.

## Conventions

- Working directory: `/opt/zw-transfer/`
- `docker-compose.yml` is the source of truth for the rendered Pingvin YAML config. Pingvin Share X reads application settings from `CONFIG_FILE`; it does not read those settings directly from container environment variables.
- `.env` carries deployment-specific deltas such as hostname, SMTP credentials and OIDC credentials. `.env.example` is the minimal install set plus common optional overrides, not an exhaustive list.
- To override another supported default, look up its `${VAR:-default}` expression in `docker-compose.yml` and add `VAR=...` to `.env`. Do not hand-edit `/opt/zw-transfer/docker-compose.yml` for local-only changes; the installer refreshes deployment files on update and preserves `.env`.
- Persistent state: Pingvin data in volume `zw-transfer-pingvin-data`; Caddy data and config in `zw-transfer-caddy-data` / `zw-transfer-caddy-config`.
- Caddy terminates TLS on 80/443 with automatic Let's Encrypt and reverse-proxies to Pingvin on `127.0.0.1:3000`.
- Pingvin's backend language is set to Dutch via `general.defaultLanguage`, so backend-generated e-mail fallbacks and relative expiry text use Dutch. The bind-mounted `patches/email.service.js` adds a deployment-specific `{descBlock}` placeholder for the share-recipient e-mail template: it appends an optional share description as one running Dutch sentence and renders shares without an expiration date as `nooit`. The file is generated from `patches/email.service.patch` by `scripts/regenerate-email-patch.sh` and re-emitted by CI on every image bump.

## How to use

### Guided mode

1. Point DNS for the public hostname to the target server.
2. Use a fresh Debian or Ubuntu server with Docker and Docker Compose installed.
3. Run this command as `root`:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/oszuidwest/zw-transfer/main/install.sh)"
```

The installer downloads the deployment files into `/opt/zw-transfer`, prompts for hostname / SMTP / OIDC credentials, writes `.env`, pulls images, gracefully stops any running stack, starts the containers, and checks that the containers are running. Re-running it on an existing install offers to keep the existing `.env` untouched.

### Manual mode

Clone the repository, then configure and start manually:

```sh
cp .env.example .env
$EDITOR .env
docker compose --env-file .env config
docker compose --env-file .env up -d
```

Fill every blank value in `.env` before starting: `APP_HOSTNAME`, `SMTP_HOST`, `SMTP_EMAIL`, `SMTP_PASSWORD`, `OIDC_DISCOVERY_URI`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET`. `APP_NAME`, `APP_URL`, `SMTP_PORT`, `SMTP_USERNAME` and `OIDC_USERNAME_CLAIM` have defaults but can be added to `.env` when needed. For SSO, create an OIDC client with this redirect URI:

```text
https://transfer.example.org/api/oauth/callback/oidc
```

Then set the OIDC values in `.env`.

## Operations

```sh
docker compose ps
docker compose logs -f pingvin
docker compose logs -f caddy
docker compose pull && docker compose up -d
```

Persistent application state lives in Docker volumes. The repository intentionally ignores local SQLite databases and uploads so deployments can start clean.

Note: changes to the inline `pingvin_config` block in `docker-compose.yml` (email templates, OIDC settings, share limits, etc.) only land in the container on a full recreate. Use `docker compose --env-file .env up -d --force-recreate pingvin`, not `restart` — the latter leaves the previous rendered config file mounted.

Validate changes before deploying:

```sh
docker compose --env-file .env config
./scripts/validate-pingvin-config.sh .env
```

The validation script renders Compose, extracts `configs.pingvin_config.content`, parses it as YAML, and checks the Pingvin-specific type expectations that are easy to break: application booleans must stay quoted strings, while `initUser.enabled` and `initUser.isAdmin` must stay real YAML booleans.

## Storage

By default Pingvin stores uploaded files in the `pingvin_data` Docker volume.

S3-compatible object storage is supported by upstream and exposed through the same `.env` contract. Set `S3_ENABLED=true` plus the bucket/credential values listed in `.env.example` to route file content to S3. The `pingvin_data` volume still holds the SQLite database and session state regardless.

Caveats:

- Multi-file ZIP downloads are disabled by upstream when S3 is on. Recipients have to download each file separately. For a transfer-style workflow that often means single big files, this is usually fine; for many-file shares it is a real UX cost.
- The bucket MUST be private. Pingvin streams downloads through its own backend rather than issuing signed URLs, so a publicly readable bucket would leak shares.
- Enabling S3 only affects new uploads. Files that already live in `pingvin_data` keep being served from there.
- No CORS or bucket lifecycle policy is required. Pingvin deletes objects itself when a share expires or is removed.
- For Backblaze B2 and some other non-AWS providers, set `S3_USE_CHECKSUM=false`.

## Version updates

The pinned Pingvin Share X image is updated by `.github/workflows/check-pingvin-release.yml`. The workflow checks the current tag in `docker-compose.yml`, fetches the latest GitHub release for `smp46/pingvin-share-x`, updates the Compose file when needed, regenerates `patches/email.service.js` against the new image via `scripts/regenerate-email-patch.sh`, validates the rendered Pingvin config via `scripts/validate-pingvin-config.sh`, and opens a pull request.

## Security

The Compose stack uses `no-new-privileges` for the application containers. Caddy drops all Linux capabilities except `NET_BIND_SERVICE`, which it needs to bind ports 80 and 443. The `Docker Security` workflow scans the Pingvin Share X and Caddy images from `docker-compose.yml` with Trivy and uploads high/critical SARIF results to GitHub Security. Pingvin is scanned for OS and application dependencies; Caddy is scanned for OS packages only, because this repo does not build the Caddy Go binary. The workflow reports upstream image findings without blocking deployments.

SSO-only is enforced both at the application (`OAUTH_DISABLE_PASSWORD=true`, `SHARE_ALLOW_REGISTRATION=false`, `OAUTH_IGNORE_TOTP=true`) and at the proxy: Caddy redirects `/auth/signIn` to the OpenID flow, blocks OAuth unlink requests, blocks TOTP endpoints, and adds an `X-Robots-Tag` noindex header. Do not override password, registration or TOTP-related defaults without updating the Caddy policy at the same time.

For mail deliverability, keep DKIM enabled at the mail provider and use a strict SPF record for the sending domain. With one mailbox provider as the only sender, `v=spf1 mx -all` is preferred over a neutral `?all` policy.
