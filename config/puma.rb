# frozen_string_literal: true

# DEPLOY_TO is set by the systemd service so this config works for both
# production (/home/deploy/left_wordle_api) and
# staging (/home/deploy/staging_left_wordle_api) from the same file.
deploy_to = ENV.fetch("DEPLOY_TO", "/home/deploy/left_wordle_api")
shared = "#{deploy_to}/shared"
rack_env = ENV.fetch("RACK_ENV", "production")

environment rack_env

workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
threads_count = ENV.fetch("PUMA_THREADS", 5).to_i
threads threads_count, threads_count

unless rack_env == "development"
  bind "unix://#{shared}/tmp/sockets/puma.sock"
  pidfile "#{shared}/tmp/pids/puma.pid"
  state_path "#{shared}/tmp/sockets/puma.state"
  stdout_redirect "#{shared}/log/puma.stdout.log", "#{shared}/log/puma.stderr.log", true
end

# Allow the reverse-proxy (caddy) user to read the socket.
# On the server: sudo usermod -a -G deploy caddy
# umask was removed from Puma 6+ DSL; set via systemd service file instead:
#   UMask=0007
