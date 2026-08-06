# frozen_string_literal: true

namespace :scheduler do
  desc "Ensure known scheduled_tasks rows exist against the release's database"
  task :seed do
    on roles(:app) do
      within release_path do
        execute :bundle, :exec, :rake, "scheduler:seed"
      end
    end
  end

  desc "Upload and enable the systemd service + timer, resolving the current rv Ruby paths (runs automatically every deploy so Ruby version bumps can't drift out of sync with the unit file)"
  task setup: "rv:install" do
    on roles(:app) do
      service = fetch(:scheduler_service)
      %w[service timer].each do |ext|
        template_path = "config/deploy/templates/#{service}.#{ext}"
        content = File.read(template_path)
          .gsub("__RV_PATH__", fetch(:rv_path))
          .gsub("__RV_RUBY_BIN__", fetch(:rv_ruby_bin))
        upload! StringIO.new(content), "/tmp/#{service}.#{ext}"
        sudo "mv /tmp/#{service}.#{ext} /etc/systemd/system/#{service}.#{ext}"
      end
      sudo "systemctl daemon-reload"
      # Only the .timer is enabled/started — the .service is oneshot and triggered by the timer.
      sudo "systemctl enable #{service}.timer"
      sudo "systemctl start #{service}.timer"
    end
  end
end

after "deploy:published", "scheduler:setup"
after "deploy:updated", "scheduler:seed"
