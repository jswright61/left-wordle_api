# frozen_string_literal: true

namespace :caddy do
  desc "Upload this stage's tracked Caddy site config, validate, and reload -- keeps config/caddy/sites the source of truth instead of hand-patched drift"
  task :sync_site do
    on roles(:app) do
      source = fetch(:caddy_site_source)
      live_path = fetch(:caddy_site_live_path)
      abort "Set :caddy_site_source for this stage (see config/deploy/production.rb)" unless source
      abort "Set :caddy_site_live_path for this stage (see config/deploy/production.rb)" unless live_path

      local_content = File.read(source)
      remote_tmp = "/tmp/#{File.basename(live_path)}.#{Time.now.to_i}"
      backup_path = "#{live_path}.bak_#{Time.now.strftime("%Y%m%d_%H%M%S")}"
      had_previous = test("[ -f #{live_path} ]")

      sudo :cp, live_path, backup_path if had_previous

      upload! StringIO.new(local_content), remote_tmp
      sudo :mv, remote_tmp, live_path

      if test(:sudo, "caddy", "validate", "--config", "/etc/caddy/Caddyfile")
        sudo "systemctl reload caddy"
        puts "  Synced and reloaded Caddy site config: #{live_path}"
      elsif had_previous
        sudo :cp, backup_path, live_path
        abort "Caddy config validation failed after syncing #{live_path} -- restored the previous version from #{backup_path}. Fix config/caddy/sites and redeploy."
      else
        abort "Caddy config validation failed after syncing #{live_path}, and there was no prior version to restore. Fix manually on the server."
      end
    end
  end
end

after "deploy:published", "caddy:sync_site"
