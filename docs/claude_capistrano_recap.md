What was created

  ┌─────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┐
  │                          File                           │                                Purpose                                │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ Gemfile                                                 │ Added capistrano + capistrano-bundler in development group            │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ Capfile                                                 │ Loads Capistrano plugins and custom tasks                             │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/deploy.rb                                        │ Shared config: repo URL, linked dirs, bundle path, rv PATH            │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/deploy/production.rb                             │ main branch → /home/deploy/left_wordle_api                            │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/deploy/staging.rb                                │ staging branch → /home/deploy/staging_left_wordle_api                 │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/puma.rb                                          │ Puma config — reads DEPLOY_TO env var so one file works for both envs │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ lib/capistrano/tasks/puma.rake                          │ puma:{start,stop,restart,status,setup} tasks via systemd              │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/deploy/templates/left-wordle-api.service         │ Production systemd unit                                               │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ config/deploy/templates/left-wordle-api-staging.service │ Staging systemd unit                                                  │
  ├─────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ Caddyfile                                               │ Caddy reverse proxy — replace domain placeholders                     │
  └─────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────┘

  ---
  First-time server setup (run once per environment)

  # 1. Upload the systemd service file and enable it
  cap production puma:setup
  cap staging puma:setup

  # 2. Configure sudoers (commands are in the .service file comments)
  # 3. Add caddy to deploy group so it can reach the puma socket
  #    ssh deploy@paula-poundstone
  #    sudo usermod -a -G deploy caddy

  Deploying

  cap production deploy   # deploys main
  cap staging deploy      # deploys staging branch

  ---
  One thing to verify before first deploy

  The rv shims path in config/deploy.rb and the systemd service files is guessed as /home/deploy/.local/share/rv/shims. Confirm the real path on the server:

  ssh deploy@paula-poundstone 'bash -lc "which bundle"'

  Then update set :default_env in config/deploy.rb and the PATH= line in both .service files to match.
