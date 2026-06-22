# Staging Troubleshooting Guide

Covers both `staging.left-wordle.com` (static client) and `api-staging.left-wordle.com` (Puma/Sinatra API).

---

## Quick reference: expected configuration

| | Staging |
|---|---|
| Client URL | `https://staging.left-wordle.com` |
| API URL | `https://api-staging.left-wordle.com` |
| Client deploy path | `/home/deploy/staging.left_wordle.com` |
| API deploy path | `/home/deploy/staging_left_wordle_api` |
| API systemd service | `left-wordle-api-staging` |
| API `CORS_ORIGINS` | `https://staging.left-wordle.com` |
| API `RACK_ENV` | `production` |
| API `DEPLOY_TO` | `/home/deploy/staging_left_wordle_api` |

---

## Verifying API environment variables

The env vars for Puma are set in the systemd service file, which is uploaded by `cap staging puma:setup`. If you edited the service template locally, you must re-run `puma:setup` and restart the service for changes to take effect.

**Check what the running process actually has:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl show left-wordle-api-staging -p Environment'
```

**Check the installed service file on the server:**
```bash
ssh deploy@paula-poundstone 'grep -E "CORS|RACK_ENV|DEPLOY_TO" /etc/systemd/system/left-wordle-api-staging.service'
```

**If the env vars are wrong or missing:**
1. Edit the template locally: `api/config/deploy/templates/left-wordle-api-staging.service`
2. Upload it: `bundle exec cap staging puma:setup`
3. Restart Puma: `bundle exec cap staging puma:restart`

---

## Verifying CORS

**Test a preflight request directly:**
```bash
curl -si -X OPTIONS https://api-staging.left-wordle.com/api/v1/game/guess \
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

If `Access-Control-Allow-Origin` is absent, CORS_ORIGINS is not set correctly (or the service wasn't restarted after it was set).

**Test a real GET request with an Origin header:**
```bash
curl -si https://api-staging.left-wordle.com/api/v1/health \
  -H "Origin: https://staging.left-wordle.com"
```

Should return `200` with `Access-Control-Allow-Origin: https://staging.left-wordle.com`.

**Common CORS mistakes:**
- Trailing slash in `CORS_ORIGINS`: `https://staging.left-wordle.com/` — browsers send origins without a trailing slash, so this will never match
- Wrong protocol: `http://` vs `https://`
- Typo in the subdomain
- Service not restarted after changing the service file

---

## Verifying the client configuration

The client's `app_config.js` is generated and uploaded by Capistrano at deploy time. It is not in the git repo.

**Check what's actually deployed:**
```bash
ssh deploy@paula-poundstone 'cat /home/deploy/staging.left_wordle.com/current/app_config.js'
```

Expected staging output:
```js
var defaults = {
    apiBaseUrl: "https://api-staging.left-wordle.com",
    apiCredentials: "omit",
    apiGameplayEnabled: false,       // ⚠️ see note below
    apiGameplayShadowMode: false,
    ...
};
```

The `apiBaseUrl` is set from `set :api_base_url` in `client/config/deploy/staging.rb`. If it's wrong, fix that file and redeploy.

**⚠️ `apiGameplayEnabled` is currently `false` in all deployed environments.**
This means the client does local evaluation only and never calls the API for gameplay. Hard mode and insane mode validation are completely bypassed because client-side validation was removed in favor of API validation. To enable API gameplay (and restore mode enforcement), `apiGameplayEnabled` must be set to `true` in `app_config.rake`. See [Enabling API Gameplay](#enabling-api-gameplay) below.

---

## Verifying the API is reachable

**Health check:**
```bash
curl -s https://api-staging.left-wordle.com/api/v1/health
# Expected: {"status":"ok"}
```

**Test a guess (no mode validation, no CORS):**
```bash
curl -s -X POST https://api-staging.left-wordle.com/api/v1/game/guess \
  -H "Content-Type: application/json" \
  -d '{"date":"2021-06-19","guess":"crane","row_index":0,"mode":"regular","prev_guesses":[]}'
```

**Test a guess from the browser's perspective (with CORS):**
```bash
curl -s -X POST https://api-staging.left-wordle.com/api/v1/game/guess \
  -H "Content-Type: application/json" \
  -H "Origin: https://staging.left-wordle.com" \
  -d '{"date":"2021-06-19","guess":"crane","row_index":0,"mode":"regular","prev_guesses":[]}'
```

The second request should include `Access-Control-Allow-Origin: https://staging.left-wordle.com` in the response headers.

---

## Checking Caddy

**Caddy status:**
```bash
ssh deploy@paula-poundstone 'sudo systemctl status caddy'
```

**Tail the staging API log:**
```bash
ssh deploy@paula-poundstone 'sudo tail -f /var/log/caddy/left-wordle-api-staging.log'
```

**Tail the staging client log:**
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
ssh deploy@paula-poundstone 'ls -la /home/deploy/staging.left_wordle.com/'
ssh deploy@paula-poundstone 'ls /home/deploy/staging.left_wordle.com/current/'
```

`current/` should contain `index.html`, `app_config.js`, `app_version.js`, `src/`, etc.

---

## Enabling API gameplay

To make the API authoritative for gameplay (required for hard/insane mode enforcement):

1. In `client/lib/capistrano/tasks/app_config.rake`, make `apiGameplayEnabled` configurable per environment:

```ruby
config_js = <<~JS
  ...
  apiGameplayEnabled: #{fetch(:api_gameplay_enabled, false)},
  ...
JS
```

2. In `client/config/deploy/staging.rb`, add:
```ruby
set :api_gameplay_enabled, true
```

3. Redeploy the client: `bundle exec cap staging deploy`

Until this is done, the client ignores the API for all gameplay evaluation and mode rules are not enforced on the deployed site.
