# frozen_string_literal: true

set :branch, "main"
set :deploy_to, "/home/deploy/left_wordle_api"
set :puma_service, "left-wordle-api"
set :scheduler_service, "left-wordle-scheduler"

server "paula-poundstone",
  user: "deploy",
  roles: %w[web app],
  ssh_options: {forward_agent: true}
