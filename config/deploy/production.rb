# frozen_string_literal: true

set :branch, "main"
set :deploy_to, "/home/deploy/left_wordle_api"
set :puma_service, "left-wordle-api"
set :scheduler_service, "left-wordle-scheduler"

# Live filename doesn't match the repo's -- historical, see
# config/caddy/sites/production.left-wordle.com's header comment.
set :caddy_site_source, "config/caddy/sites/production.left-wordle.com"
set :caddy_site_live_path, "/etc/caddy/sites-available/client_and_api.left-wordle.com"

server "paula-poundstone",
  user: "deploy",
  roles: %w[web app],
  ssh_options: {forward_agent: true}
