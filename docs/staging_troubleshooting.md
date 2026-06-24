# Staging Troubleshooting Guide

Covers `staging.left-wordle.com`, which serves both the static client and the Puma/Sinatra API under a single domain. Caddy routes `/api/*` to Puma and everything else to the static file tree.

---

## Quick reference: expected configuration

| | Staging |
|---|---|
| Client URL | `https://staging.left-wordle.com` |
| API URL | `https://staging.left-wordle.com/api/v1/...` |
| Client deploy path | `/home/deploy/staging.left-wordle.com` |
| API deploy path | `/home/deploy/staging_left_wordle_api` |
| API systemd service | `left-wordle-api-staging` |
| API `RACK_ENV` | `production` |
| API `DEPLOY_TO` | `/home/deploy/staging_left_wordle_api` |
| CORS config | `shared/config/app_config.yml` (symlinked per release) |

---

## Verifying API environment variables

The env vars for Puma (`RACK_ENV`, `DEPLOY_TO`, `PATH`, `HOME`) are set in the systemd service file (`/etc/systemd/system/left-wordle-api-staging.service`). See `config/deploy/templates/left-wordle-api-staging.service` in the repo for the template.

**Check what the running process actually has:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl show left-wordle-api-staging -p Environment'
```

**Check the installed service file:**
```bash
ssh deploy@paula-poundstone 'grep -E "RACK_ENV|DEPLOY_TO|^Environment" /etc/systemd/system/left-wordle-api-staging.service'
```

**If an env var is wrong:** edit the template locally, re-upload it (manually or via `bundle exec cap staging puma:setup`), then `bundle exec cap staging puma:restart`.

---

## Verifying the CORS config file

CORS allowed origins are configured in `shared/config/app_config.yml` on the server. Capistrano symlinks this into each release as `config/app_config.yml`. The API reads it at startup.

**Check the config file on the server:**
```bash
ssh deploy@paula-poundstone 'cat /home/deploy/staging_left_wordle_api/shared/config/app_config.yml'
```

Expected staging content:
```yaml
cors_origins:
  - https://staging.left-wordle.com
```

**Check that the symlink exists in the current release:**
```bash
ssh deploy@paula-poundstone 'ls -la /home/deploy/staging_left_wordle_api/current/config/'
```

`app_config.yml` should appear as a symlink to `../../../shared/config/app_config.yml`.

**If the file is missing or wrong:**
1. Create or edit it: `ssh deploy@paula-poundstone 'nano /home/deploy/staging_left_wordle_api/shared/config/app_config.yml'`
2. Restart Puma so the app re-reads it: `bundle exec cap staging puma:restart`

---

## Verifying CORS

**Test a preflight request directly:**
```bash
curl -si -X OPTIONS https://staging.left-wordle.com/api/v1/game/guess \
  -H "Origin: https://staging.left-wordle.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type"
```

Expected response headers:
```
Access-Control-Allow-Origin: https://staging.left-wordle.com
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
Vary: Origin
```

If `Access-Control-Allow-Origin` is absent, check the `app_config.yml` on the server and restart Puma.

**Test a real GET request with an Origin header:**
```bash
curl -si https://staging.left-wordle.com/api/v1/health \
  -H "Origin: https://staging.left-wordle.com"
```

Should return `200` with `Access-Control-Allow-Origin: https://staging.left-wordle.com`.

**Common CORS mistakes:**
- Trailing slash in `cors_origins`: `https://staging.left-wordle.com/` — browsers send origins without a trailing slash, so this will never match
- Wrong protocol: `http://` vs `https://`
- Typo in the subdomain
- Puma not restarted after editing `app_config.yml`

---

## Verifying the client configuration

The client's `app_config.js` is generated and uploaded by Capistrano at deploy time (from `client/lib/capistrano/tasks/app_config.rake`). It is not in the git repo.

**Check what's actually deployed:**
```bash
ssh deploy@paula-poundstone 'cat /home/deploy/staging.left-wordle.com/current/app_config.js'
```

Expected staging output:
```js
var defaults = {
    apiBaseUrl: "https://staging.left-wordle.com",
    apiCredentials: "omit",
    apiRequestTimeoutMs: 3000,
    passkeyAuthEnabled: false,
    serverSyncEnabled: false
};
```

The `apiBaseUrl` is set from `set :api_base_url` in `client/config/deploy/staging.rb`. If it's wrong, fix that file and redeploy.

---

## Verifying the API is reachable

**Health check:**
```bash
curl -s https://staging.left-wordle.com/api/v1/health
# Expected: {"status":"ok"}
```

**Test a guess (no CORS):**
```bash
curl -s -X POST https://staging.left-wordle.com/api/v1/game/guess \
  -H "Content-Type: application/json" \
  -d '{"date":"2021-06-19","guess":"crane","row_index":0,"mode":"regular","prev_guesses":[]}'
```

**Test a guess from the browser's perspective (with CORS):**
```bash
curl -s -X POST https://staging.left-wordle.com/api/v1/game/guess \
  -H "Content-Type: application/json" \
  -H "Origin: https://staging.left-wordle.com" \
  -d '{"date":"2021-06-19","guess":"crane","row_index":0,"mode":"regular","prev_guesses":[]}'
```

The second request should include `Access-Control-Allow-Origin: https://staging.left-wordle.com` in the response headers.

---

## Checking Caddy

The staging Caddy block routes `/api/*` to Puma and serves everything else as static files:

```
staging.left-wordle.com {
    tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

    handle /api/* {
        reverse_proxy unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock
    }

    handle {
        root * /home/deploy/staging.left-wordle.com/current
        file_server
        try_files {path} {path}.html {path}/index.html
    }

    log {
        output file /var/log/caddy/left-wordle-staging.log
    }
}
```

**`handle` vs `handle_path`:** Use `handle /api/*`, not `handle_path /api/*`. `handle_path` strips the matched prefix before proxying — so `/api/v1/game/guess` would arrive at Sinatra as `/v1/game/guess`, matching no route and returning 404. `handle` passes the path through unchanged.

**Caddy status:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl status caddy'
```

**Tail the staging log:**
```bash
ssh deploy@paula-poundstone 'sudo tail -f /var/log/caddy/left-wordle-staging.log'
```

**Reload Caddy after config changes:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl reload caddy'
```

**Validate the Caddyfile before reloading:**
```bash
ssh deploy@paula-poundstone 'sudo caddy validate --config /etc/caddy/Caddyfile'
```

---

## Checking Puma

**Service status:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl status left-wordle-api-staging'
```

**Puma stdout/stderr logs:**
```bash
ssh deploy@paula-poundstone 'tail -f /home/deploy/staging_left_wordle_api/shared/log/puma.stdout.log'
ssh deploy@paula-poundstone 'tail -f /home/deploy/staging_left_wordle_api/shared/log/puma.stderr.log'
```

**Verify the socket exists:**
```bash
ssh deploy@paula-poundstone 'ls -la /home/deploy/staging_left_wordle_api/shared/tmp/sockets/'
```

The socket (`puma.sock`) must exist and be readable by the `caddy` user (via the `deploy` group). If permissions are wrong: `sudo usermod -a -G deploy caddy && sudo systemctl restart caddy`.

---

## Verifying the deploy directory

**Check the symlink and release files:**
```bash
ssh deploy@paula-poundstone 'ls -la /home/deploy/staging.left-wordle.com/'
ssh deploy@paula-poundstone 'ls /home/deploy/staging.left-wordle.com/current/'
```

`current/` should contain `index.html`, `app_config.js`, `app_version.js`, `src/`, etc.
