# frozen_string_literal: true

lock "~> 3.19"

set :application, "left_wordle_api"
set :repo_url, "deploy@paula-poundstone:/home/deploy/git/left_wordle_api.git"

# The version to install and put on PATH via rv (see lib/capistrano/tasks/rv.rake).
# rv does not use a shims directory, so PATH must point at this version's actual
# bin dirs — resolved dynamically at deploy time, no manual path bookkeeping needed.
set :ruby_version, File.read(File.expand_path("../.ruby-version", __dir__)).strip

set :linked_files, %w[config/app_config.yml]
set :linked_dirs, %w[log tmp/pids tmp/sockets bundle]

set :bundle_path, -> { shared_path.join("bundle") }
set :bundle_flags, "--quiet"

set :keep_releases, 5
