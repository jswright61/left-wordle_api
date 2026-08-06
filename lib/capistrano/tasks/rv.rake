# frozen_string_literal: true

namespace :rv do
  desc "Install the Ruby version pinned in .ruby-version and resolve its bin paths"
  task :install do
    on roles(:app) do
      ruby_version = fetch(:ruby_version)
      rv = fetch(:rv_bin)

      execute rv, "ruby", "install", ruby_version

      ruby_exe = capture(rv, "ruby", "find", ruby_version).strip
      ruby_bin = File.dirname(ruby_exe)

      gem_paths = capture(File.join(ruby_bin, "gem"), "environment", "gempath").strip.split(":")
      path = (gem_paths.map { |dir| File.join(dir, "bin") } + [ruby_bin] + %w[
        /home/deploy/bin /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin
      ]).join(":")

      set :rv_ruby_bin, ruby_bin
      set :rv_path, path
      set :default_env, fetch(:default_env, {}).merge("PATH" => path)

      # capistrano/setup snapshots SSHKit.config.default_env from :default_env
      # once at Capfile load time, before this task ever runs, so `set
      # :default_env` above (which replaces the hash object) never reaches
      # SSHKit. Update SSHKit's actual config directly so later `execute`
      # calls (e.g. bundler:config) inherit PATH.
      SSHKit.config.default_env = SSHKit.config.default_env.merge("PATH" => path)
    end
  end
end

before "deploy:check", "rv:install"
