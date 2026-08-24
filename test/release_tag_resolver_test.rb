# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/capistrano/release_tag_resolver"

class ReleaseTagResolverTest < Minitest::Test
  COMMIT = "5c16e3808086257949d3543769027b900207bd52"
  OTHER_COMMIT = "873a888647f753bbb11e64ca7740a538b2e52e1a"

  def ls_remote_line(sha, tag, peeled: false)
    ref = "refs/tags/#{tag}"
    ref += "^{}" if peeled
    "#{sha}\t#{ref}\n"
  end

  def test_picks_the_only_matching_tag
    tags_output = ls_remote_line(COMMIT, "v0.9.11")

    assert_equal "v0.9.11", ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
  end

  def test_a_commit_with_multiple_semver_tags_picks_the_highest
    # A major bump re-tags the same commit that an earlier 0.x tag pointed
    # at, so both tags coexist on one commit rather than the old one being
    # deleted.
    tags_output =
      ls_remote_line(COMMIT, "v0.9.11") +
      ls_remote_line(COMMIT, "v1.0.0") +
      ls_remote_line(OTHER_COMMIT, "v0.9.10")

    assert_equal "v1.0.0", ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
  end

  def test_semver_comparison_is_numeric_not_lexicographic
    # String-sorting "v0.9.10" and "v0.9.9" gets this backwards: "9" > "1"
    # as characters, so a naive sort would rank v0.9.9 above v0.9.10.
    tags_output =
      ls_remote_line(COMMIT, "v0.9.9") +
      ls_remote_line(COMMIT, "v0.9.10")

    assert_equal "v0.9.10", ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
    refute_equal "v0.9.10", ["v0.9.9", "v0.9.10"].max, "sanity check: string sort disagrees with SemVer here"
  end

  def test_ignores_tags_on_other_commits
    tags_output = ls_remote_line(OTHER_COMMIT, "v1.0.0")

    assert_nil ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
  end

  def test_ignores_non_semver_tags
    tags_output =
      ls_remote_line(COMMIT, "latest") +
      ls_remote_line(COMMIT, "v1.0.0-rc1")

    assert_nil ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
  end

  def test_uses_the_peeled_line_for_annotated_tags
    # Annotated tags report the tag object's own SHA on the direct line and
    # the commit SHA on the "^{}" peeled line; only the peeled line should match.
    annotated_tag_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    tags_output =
      ls_remote_line(annotated_tag_sha, "v1.0.0") +
      ls_remote_line(COMMIT, "v1.0.0", peeled: true)

    assert_equal "v1.0.0", ReleaseTagResolver.highest_tag_for_commit(tags_output, COMMIT)
  end
end
