# frozen_string_literal: true

# capistrano-bundler 2.2.0 uses deprecated `bundle config --local` syntax.
# Override the task to use `bundle config set --local` until the gem is fixed.
Rake::Task["bundler:config"].clear

namespace :bundler do
  task :config do
    on roles(fetch(:bundle_roles)) do
      within release_path do
        with fetch(:bundle_env_variables, {}) do
          execute :bundle, "config", "set", "--local", "deployment", fetch(:bundle_deployment) { true }
          execute :bundle, "config", "set", "--local", "path", fetch(:bundle_path) if fetch(:bundle_path)
          if (without = fetch(:bundle_without))
            execute :bundle, "config", "set", "--local", "without", without.join(":")
          end
          if (with_gems = fetch(:bundle_with))
            execute :bundle, "config", "set", "--local", "with", with_gems.join(":")
          end
        end
      end
    end
  end
end
