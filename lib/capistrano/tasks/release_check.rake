# frozen_string_literal: true

namespace :deploy do
  task :check_release_tag do
    repo = fetch(:repo_url)
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

  task :write_version_tag do
    version_tag = fetch(:release_version_tag)
    on roles(:app) do
      upload! StringIO.new(version_tag), release_path.join("VERSION")
    end
  end
end

before "git:check", "deploy:check_release_tag"
after "git:create_release", "deploy:write_version_tag"
