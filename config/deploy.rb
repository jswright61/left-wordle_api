# frozen_string_literal: true

lock "~> 3.19"

set :application, "left_wordle_api"
set :repo_url, "ssh://git@codeberg.org/jswright61/left_wordle_api.git"

# rv does not use a shims directory — it adds the actual Ruby binary paths to PATH.
# SSH non-interactive sessions skip .zshrc, so we set those paths explicitly here.
# If the Ruby version changes, update the three rv paths below to match.
# Verify the live paths on the server with:
#   ssh deploy@paula-poundstone 'bash -lc "echo $PATH"'
set :default_env, {
  "PATH" => "/home/deploy/.local/share/rv/gems/ruby/4.0.0/bin:/home/deploy/.local/share/rv/rubies/ruby-4.0.5/lib/ruby/gems/4.0.0/bin:/home/deploy/.local/share/rv/rubies/ruby-4.0.5/bin:/home/deploy/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
}

set :linked_files, %w[config/app_config.yml]
set :linked_dirs, %w[log tmp/pids tmp/sockets bundle]

set :bundle_path, -> { shared_path.join("bundle") }
set :bundle_flags, "--quiet"

set :keep_releases, 5
