# zw-transfer

An opinionated, SSO-only Docker Compose deployment of [Pingvin Share X](https://github.com/smp46/pingvin-share-x), pre-configured as **ZuidWest Transfer** (default branding, Dutch e-mail templates, password login disabled, registration off, 1 TB share size, recipients panel always visible). Override any default via `.env` to deploy under your own brand.

## Conventions

- Working directory: `/opt/zw-transfer/`
- `docker-compose.yml` is the single source of truth for defaults — every Pingvin setting is interpolated from `${VAR:-default}` expressions there.
- `.env` only carries deployment-specific deltas (hostname, app name, SMTP credentials, OIDC credentials, plus the two enable flags). See `.env.example` for the full list.
- All other Pingvin knobs (CSS overrides, share limits, OIDC scope, init user, etc.) fall through to compose defaults. To override one, look up the variable in `docker-compose.yml` and add it to `.env`.
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

The installer downloads the deployment files into `/opt/zw-transfer`, prompts for hostname / app name / SMTP / OIDC credentials, writes `.env`, gracefully stops any running stack, pulls images, starts the containers, and verifies they are healthy. Re-running it on an existing install offers to keep the existing `.env` untouched.

### Manual mode

Clone the repository, then configure and start manually:

```sh
cp .env.example .env
$EDITOR .env
docker compose --env-file .env config
docker compose --env-file .env up -d
```

Set `SMTP_PASSWORD` in `.env` before starting. For SSO, create an OIDC client with this redirect URI:

```text
https://transfer.example.org/api/oauth/callback/oidc
```

Then set `OIDC_DISCOVERY_URI`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` in `.env`.

## Operations

```sh
docker compose ps
docker compose logs -f pingvin
docker compose logs -f caddy
docker compose pull && docker compose up -d
```

Persistent application state lives in Docker volumes. The repository intentionally ignores local SQLite databases and uploads so deployments can start clean.

Note: changes to the inline `pingvin_config` block in `docker-compose.yml` (email templates, OIDC settings, share limits, etc.) only land in the container on a full recreate. Use `docker compose --env-file .env up -d --force-recreate pingvin`, not `restart` — the latter leaves the previous rendered config file mounted.

## Version updates

The pinned Pingvin Share X image is updated by `.github/workflows/check-pingvin-release.yml`. The workflow checks the current tag in `docker-compose.yml`, fetches the latest GitHub release for `smp46/pingvin-share-x`, updates the Compose file when needed, regenerates `patches/email.service.js` against the new image via `scripts/regenerate-email-patch.sh`, validates the result, and opens a pull request.

## Security

The Compose stack uses `no-new-privileges` for the application containers. Caddy drops all Linux capabilities except `NET_BIND_SERVICE`, which it needs to bind ports 80 and 443. The `Docker Security` workflow scans the Pingvin Share X and Caddy images from `docker-compose.yml` with Trivy and uploads SARIF results to GitHub Security. Pingvin is scanned for OS and application dependencies; Caddy is scanned for OS packages only, because this repo does not build the Caddy Go binary. The workflow reports upstream image findings without blocking deployments.

SSO-only is enforced both at the application (`OAUTH_DISABLE_PASSWORD=true`, `SHARE_ALLOW_REGISTRATION=false`) and at the proxy: Caddy redirects `/auth/signIn` to the OpenID flow, blocks OAuth unlink requests, blocks TOTP endpoints, and adds an `X-Robots-Tag` noindex header.

For mail deliverability, keep DKIM enabled at the mail provider and use a strict SPF record for the sending domain. With one mailbox provider as the only sender, `v=spf1 mx -all` is preferred over a neutral `?all` policy.
