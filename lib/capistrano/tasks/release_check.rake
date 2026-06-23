# frozen_string_literal: true

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

            git push paula #{deploy_tag}

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
end

before "git:check", "deploy:check_release_tag"
after "git:create_release", "deploy:write_version_tag"
