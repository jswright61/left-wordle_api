# frozen_string_literal: true

set :branch, "staging"
set :deploy_to, "/home/deploy/staging_left_wordle_api"
set :puma_service, "left-wordle-api-staging"
set :scheduler_service, "left-wordle-scheduler-staging"

set :caddy_site_source, "config/caddy/sites/staging.left-wordle.com"
set :caddy_site_live_path, "/etc/caddy/sites-available/staging_client_and_api.left-wordle.com"

server "paula-poundstone",
  user: "deploy",
  roles: %w[web app],
  ssh_options: {forward_agent: true}
