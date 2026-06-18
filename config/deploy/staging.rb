# frozen_string_literal: true

set :branch, "staging"
set :deploy_to, "/home/deploy/staging_left_wordle_api"
set :puma_service, "left-wordle-api-staging"

server "paula-poundstone",
  user: "deploy",
  roles: %w[web app],
  ssh_options: {forward_agent: true}
