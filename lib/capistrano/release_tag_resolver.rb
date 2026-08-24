# frozen_string_literal: true

require "rubygems/version"

module ReleaseTagResolver
  TAG_PATTERN = /\Av\d+\.\d+\.\d+\z/

  # tags_output is `git ls-remote --tags` output: lines of "<sha>\t<ref>",
  # where annotated tags are peeled to their commit via a second
  # "<sha>\t<ref>^{}" line. Returns the highest SemVer tag (by numeric
  # version, not string order) pointing at commit_sha, or nil.
  def self.highest_tag_for_commit(tags_output, commit_sha)
    matching_tags = tags_output.lines.filter_map do |line|
      tag_sha, ref = line.split
      tag = ref.to_s.delete_prefix("refs/tags/").chomp("^{}")
      tag if tag_sha == commit_sha && tag.match?(TAG_PATTERN)
    end

    matching_tags.max_by { |tag| Gem::Version.new(tag.delete_prefix("v")) }
  end
end
