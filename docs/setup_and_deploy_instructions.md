# Setup and Deploy Instructions

This app deploys to `paula-poundstone` (Ubuntu Server) as the `deploy` user using Capistrano, Puma, and Caddy.

## Environments

| Environment | Branch | Deploy path | Systemd service | Systemd scheduler timer |
|---|---|---|---|---|
| Production | `main` | `/home/deploy/left_wordle_api` | `left-wordle-api` | `left-wordle-scheduler.timer` |
| Staging | `staging` | `/home/deploy/staging_left_wordle_api` | `left-wordle-api-staging` | `left-wordle-scheduler-staging.timer` |

---

## Prerequisites

### Local machine

- SSH access to `deploy@paula-poundstone` (with agent forwarding so the server can pull from Codeberg)
- Capistrano gems installed: `bundle install`

### Server (one-time)

The `deploy` user and server must exist. The following need to be set up before the first deploy.

#### 1. Install rv and Ruby 4.0.5

Install rv on the server as the `deploy` user, then install Ruby:

```bash
ssh deploy@paula-poundstone
rv install 4.0.5
rv use 4.0.5
```

#### 2. Confirm the rv PATH

rv does not use a shims directory — it adds the actual Ruby binary directories to PATH directly. The PATH is hardcoded in `config/deploy.rb` and both systemd service files (Capistrano SSH sessions skip `.zshrc`). Verify the live paths on the server:

```bash
ssh deploy@paula-poundstone 'bash -lc "echo $PATH"'
```

If the paths differ from what is set in the files (e.g. after a Ruby version upgrade), update the `PATH` value in all three places:

- `set :default_env` in `config/deploy.rb`
- `Environment=PATH=...` in `config/deploy/templates/left-wordle-api.service`
- `Environment=PATH=...` in `config/deploy/templates/left-wordle-api-staging.service`

#### 3. Install Caddy

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy
```

#### 4. Allow the Caddy process to reach the Puma socket

Puma's Unix socket is created with group `deploy` and permissions `660`. Add the `caddy` user to the `deploy` group:

```bash
sudo usermod -a -G deploy caddy
```

#### 5. Configure sudoers for the deploy user

The deploy user needs to manage the systemd services without a password.

Use `visudo -f` to create each drop-in file — it validates syntax before saving and sets the correct permissions.

**Production:**

```bash
sudo visudo -f /etc/sudoers.d/left-wordle-api
```

Enter the following content:

```
deploy ALL=(ALL) NOPASSWD: \
  /bin/systemctl start left-wordle-api, \
  /bin/systemctl stop left-wordle-api, \
  /bin/systemctl reload-or-restart left-wordle-api, \
  /bin/systemctl reload left-wordle-api, \
  /bin/systemctl restart left-wordle-api, \
  /bin/systemctl daemon-reload, \
  /bin/systemctl enable left-wordle-api, \
  /bin/systemctl status left-wordle-api
```

**Staging:**

```bash
sudo visudo -f /etc/sudoers.d/left-wordle-api-staging
```

Enter the following content:

```
deploy ALL=(ALL) NOPASSWD: \
  /bin/systemctl start left-wordle-api-staging, \
  /bin/systemctl stop left-wordle-api-staging, \
  /bin/systemctl reload-or-restart left-wordle-api-staging, \
  /bin/systemctl reload left-wordle-api-staging, \
  /bin/systemctl restart left-wordle-api-staging, \
  /bin/systemctl daemon-reload, \
  /bin/systemctl enable left-wordle-api-staging, \
  /bin/systemctl status left-wordle-api-staging
```

#### 6. Install the systemd service files

The service files live in `config/deploy/templates/` in this repo. They are plain text — read them to understand exactly what they do before installing. Copy each one to `/etc/systemd/system/` on the server.

**Production:**
```bash
# From your local machine:
scp config/deploy/templates/left-wordle-api.service deploy@paula-poundstone:/tmp/
ssh deploy@paula-poundstone 'sudo mv /tmp/left-wordle-api.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable left-wordle-api'
```

**Staging:**
```bash
scp config/deploy/templates/left-wordle-api-staging.service deploy@paula-poundstone:/tmp/
ssh deploy@paula-poundstone 'sudo mv /tmp/left-wordle-api-staging.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable left-wordle-api-staging'
```

If you prefer, `cap staging puma:setup` (and `cap production puma:setup`) automate these same steps — they upload the file from `config/deploy/templates/`, move it to `/etc/systemd/system/`, and run `daemon-reload` + `enable`. There is no magic beyond that.

If the PATH in the service file ever needs updating (e.g. after a Ruby version upgrade), edit the file in the repo and re-run the `scp` + `mv` steps above, then `sudo systemctl daemon-reload` and restart the service.

#### 7. Install the scheduler timer

Recurring tasks (e.g. the daily stats summary email) are driven by a `scheduled_tasks`
database table and a systemd timer that ticks every 5 minutes, running
`bundle exec rake scheduler:tick` to check which rows are due. This is separate
from the Puma service — it's a oneshot `.service` unit triggered by a `.timer` unit,
not something that stays running.

`cap production scheduler:setup` (and `cap staging scheduler:setup`) upload both the
`.service` and `.timer` files from `config/deploy/templates/`, then enable + start
the `.timer` (the `.service` itself is never enabled directly — the timer triggers it).

After the first deploy, `scheduler:seed` (hooked to run automatically after every
deploy) ensures the known scheduled tasks exist in the database — currently just
`stats:daily_summary`, running daily at 05:15 UTC. It's safe to rerun and never
overwrites a row that's already there, so tweaking a schedule by hand in the
database (e.g. changing `run_at` or `enabled`) persists across deploys.

#### 8. Create the application config file

CORS origins and other per-environment settings live in `shared/config/app_config.yml` on the server. Capistrano symlinks it into each release as `config/app_config.yml`. The file is gitignored — create it once manually from the sample.

**Production:**
```bash
ssh deploy@paula-poundstone 'mkdir -p /home/deploy/left_wordle_api/shared/config'
scp config/app_config.yml.sample deploy@paula-poundstone:/home/deploy/left_wordle_api/shared/config/app_config.yml
ssh deploy@paula-poundstone 'nano /home/deploy/left_wordle_api/shared/config/app_config.yml'
```

Set `cors_origins` to the production frontend URL:
```yaml
cors_origins:
  - https://left-wordle.com
```

**Staging:**
```bash
ssh deploy@paula-poundstone 'mkdir -p /home/deploy/staging_left_wordle_api/shared/config'
scp config/app_config.yml.sample deploy@paula-poundstone:/home/deploy/staging_left_wordle_api/shared/config/app_config.yml
ssh deploy@paula-poundstone 'nano /home/deploy/staging_left_wordle_api/shared/config/app_config.yml'
```

Set `cors_origins` to the staging frontend URL:
```yaml
cors_origins:
  - https://staging.left-wordle.com
```

#### 9. Run the first deploy

```bash
cap production deploy
cap staging deploy
```

#### 10. Configure Caddy

Replace the domain placeholders in `Caddyfile`, then copy it to the server:

```bash
scp Caddyfile deploy@paula-poundstone:/tmp/Caddyfile
ssh deploy@paula-poundstone 'sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy'
```

Caddy will obtain TLS certificates from Let's Encrypt automatically on first request.

---

## Routine deploys

```bash
cap production deploy   # deploys the main branch
cap staging deploy      # deploys the staging branch
```

Each deploy:

1. Clones the repo into a timestamped release directory
2. Runs `bundle install` (gems are cached in `shared/bundle`)
3. Symlinks shared dirs (`log/`, `tmp/pids/`, `tmp/sockets/`, `bundle/`)
4. Flips the `current` symlink to the new release
5. Sends `systemctl reload-or-restart` to Puma (graceful restart via USR2)
6. Prunes old releases, keeping the 5 most recent

---

## Puma management

```bash
cap production puma:start
cap production puma:stop
cap production puma:restart
cap production puma:status

cap staging puma:start
cap staging puma:stop
cap staging puma:restart
cap staging puma:status
```

---

## Directory layout on the server

```
/home/deploy/left_wordle_api/          ← production deploy root
  current -> releases/20260616120000/  ← symlink to active release
  releases/
    20260616120000/                    ← each deploy gets a timestamped dir
      ...app files...
      log/        -> ../../shared/log
      tmp/pids/   -> ../../shared/tmp/pids
      tmp/sockets/-> ../../shared/tmp/sockets
      bundle/     -> ../../shared/bundle
  shared/
    log/
    tmp/
      pids/
      sockets/
    bundle/                            ← gem cache, persists across releases

/home/deploy/staging_left_wordle_api/  ← staging deploy root (same structure)
```
