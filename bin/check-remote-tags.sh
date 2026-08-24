#!/usr/bin/env bash
set -euo pipefail

# Prints the newest SemVer tag and its commit hash from tab-separated
# "<sha>\t<tag>" lines on stdin. Comparing zero-padded segments keeps this
# numeric (v0.9.10 > v0.9.9) without relying on GNU `sort -V`, which BSD/macOS
# sort doesn't have.
pick_highest() {
  awk -F'\t' '
    {
      sha = $1; tag = $2
      if (tag !~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) next
      split(substr(tag, 2), v, ".")
      key = sprintf("%010d.%010d.%010d", v[1], v[2], v[3])
      if (key > best_key) { best_key = key; best_tag = tag; best_sha = sha }
    }
    END { if (best_tag != "") print best_tag "\t" best_sha }
  '
}

# Local tags: git rev-list resolves both annotated and lightweight tags to
# their commit sha directly.
local_tag_lines() {
  git tag -l 'v*' | while IFS= read -r tag; do
    sha="$(git rev-list -n1 "$tag" 2>/dev/null || true)"
    [[ -n "$sha" ]] && printf '%s\t%s\n' "$sha" "$tag"
  done
}

# Remote tags: ls-remote lists annotated tags twice -- once at the tag
# object's own sha, once peeled ("^{}") at the commit sha. Prefer the peeled
# line so we always report a commit hash, matching local_tag_lines above.
remote_tag_lines() {
  git ls-remote --tags "$1" 'v*' | awk '
    {
      sha = $1; ref = $2
      peeled = (ref ~ /\^\{\}$/)
      if (peeled) sub(/\^\{\}$/, "", ref)
      tag = ref
      sub(/^refs\/tags\//, "", tag)
      if (!(tag in resolved) || peeled) resolved[tag] = sha
    }
    END { for (t in resolved) print resolved[t] "\t" t }
  '
}

report() {
  local label="$1" result tag sha
  echo "=== $label ==="
  result="$(pick_highest)"
  if [[ -z "$result" ]]; then
    echo "(no version tags found)"
    return
  fi
  IFS=$'\t' read -r tag sha <<<"$result"
  echo "$tag (${sha:0:7})"
}

local_tag_lines | report "local"

while IFS= read -r remote; do
  remote_tag_lines "$remote" | report "$remote"
done < <(git remote)
