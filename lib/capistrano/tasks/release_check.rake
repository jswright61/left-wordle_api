# frozen_string_literal: true

# Capistrano's valid_release_path? expects 14-digit timestamps; override to
# accept the custom format set by deploy:set_readable_release_path.
module Capistrano
  module DSL
    module Paths
      def valid_release_path?(release)
        !!release.match(/\A\d{4}-\d{2}-\d{2}_\d{2}\.\d{2}\.\d{2}__/)
      end
    end
  end
end

namespace :deploy do
  task :check_release_tag do
    repo = fetch(:repo_url)
    deploy_tag = ENV["DEPLOY_TAG"]

    if deploy_tag
      tags_output = `git ls-remote --tags #{repo}`
      tag_line = tags_output.lines.find do |line|
        ref = line.split.last
        ref.delete_prefix("refs/tags/").chomp("^{}") == deploy_tag
      end

      unless tag_line
        abort <<~MSG

          Deploy aborted: tag '#{deploy_tag}' not found on remote.
          Push the tag before deploying:

            git push paula-poundstone #{deploy_tag}

        MSG
      end

      commit_sha = tags_output.lines.find do |line|
        line.split.last == "refs/tags/#{deploy_tag}^{}"
      end&.split&.first || tag_line.split.first

      puts "  Release tag verified: #{deploy_tag} (#{commit_sha[0, 8]}) [pinned]"
      set :branch, deploy_tag
      set :release_version_tag, deploy_tag
    else
      branch = fetch(:branch)

      sha_line = `git ls-remote #{repo} refs/heads/#{branch}`.strip
      abort "  ERROR: Could not resolve remote branch '#{branch}'" if sha_line.empty?
      commit_sha = sha_line.split.first

      tags_output = `git ls-remote --tags #{repo}`
      version_tag = tags_output.lines.find do |line|
        tag_sha, ref = line.split
        tag = ref.to_s.delete_prefix("refs/tags/").chomp("^{}")
        tag_sha == commit_sha && tag.match?(/\Av\d+\.\d+\.\d+\z/)
      end&.then do |line|
        line.split.last.delete_prefix("refs/tags/").chomp("^{}")
      end

      if version_tag
        puts "  Release tag verified: #{version_tag} (#{commit_sha[0, 8]})"
        set :release_version_tag, version_tag
      else
        abort <<~MSG

          Deploy aborted: #{commit_sha[0, 8]} (tip of '#{branch}') has no version tag.
          Tag the commit before deploying:

            git tag -a vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z

        MSG
      end
    end
  end

  task :write_version_tag do
    version_tag = fetch(:release_version_tag)
    on roles(:app) do
      upload! StringIO.new(version_tag), release_path.join("VERSION")
    end
  end

  # Capistrano's deploy:new_release_path calls set_release_path(now) where now
  # returns %Y%m%d%H%M%S. We correct it here as a prerequisite of git:create_release
  # so it runs after new_release_path sets the path but before the mkdir + archive,
  # without disturbing the after-hook that wires new_release_path → git:create_release.
  task :set_readable_release_path do
    ts = Time.now.utc.strftime("%Y-%m-%d_%H.%M.%S__#{fetch(:release_version_tag)}")
    set_release_path(ts)
  end
end

before "git:check", "deploy:check_release_tag"
before "git:create_release", "deploy:set_readable_release_path"
after "git:create_release", "deploy:write_version_tag"
