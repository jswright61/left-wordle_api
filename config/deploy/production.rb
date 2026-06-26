# frozen_string_literal: true

set :branch, "main"
set :deploy_to, "/home/deploy/left_wordle_api"
set :puma_service, "left-wordle-api"

Environment=CORS_ORIGINS="https://left-wordle.com"

server "paula-poundstone",
  user: "deploy",
  roles: %w[web app],
  ssh_options: {forward_agent: true}
