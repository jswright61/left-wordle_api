# frozen_string_literal: true

namespace :puma do
  desc "Start puma via systemd"
  task :start do
    on roles(:app) do
      sudo "systemctl start #{fetch(:puma_service)}"
    end
  end

  desc "Stop puma via systemd"
  task :stop do
    on roles(:app) do
      sudo "systemctl stop #{fetch(:puma_service)}"
    end
  end

  desc "Restart puma via systemd (graceful)"
  task :restart do
    on roles(:app) do
      sudo "systemctl reload-or-restart #{fetch(:puma_service)}"
    end
  end

  desc "Show puma service status"
  task :status do
    on roles(:app) do
      execute :sudo, "systemctl status #{fetch(:puma_service)}"
    end
  end

  desc "Upload and enable the systemd service (run once during server setup)"
  task :setup do
    on roles(:app) do
      service = fetch(:puma_service)
      template_path = "config/deploy/templates/#{service}.service"
      upload! template_path, "/tmp/#{service}.service"
      sudo "mv /tmp/#{service}.service /etc/systemd/system/#{service}.service"
      sudo "systemctl daemon-reload"
      sudo "systemctl enable #{service}"
    end
  end
end

after "deploy:published", "puma:restart"
