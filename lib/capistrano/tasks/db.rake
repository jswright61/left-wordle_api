# frozen_string_literal: true

namespace :db do
  desc "Run pending Sequel migrations against the release's database"
  task :migrate do
    on roles(:app) do
      within release_path do
        execute :bundle, :exec, :rake, "db:migrate"
      end
    end
  end
end

after "deploy:updated", "db:migrate"
