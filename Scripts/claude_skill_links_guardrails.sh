#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Claude Code discovers project skills only under .claude/skills, while the
# repository keeps its skills under .agents/skills for Codex and RepoPrompt
# agents. Each repository skill is exposed through one relative symlink so both
# runtimes read the same files. The directory itself stays real because
# RepoPrompt installs its own workspace skills into it; those entries are not
# symlinks into .agents/skills and are ignored here.
source_root=".agents/skills"
link_root=".claude/skills"
failures=0

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

if [[ ! -d "$source_root" ]]; then
  fail "$source_root is missing"
fi
if [[ -L "$link_root" ]]; then
  fail "$link_root must be a real directory, not a symlink"
elif [[ ! -d "$link_root" ]]; then
  fail "$link_root is missing"
fi

if [[ "$failures" -eq 0 ]]; then
  for source_dir in "$source_root"/*/; do
    name="$(basename "$source_dir")"
    link="$link_root/$name"
    expected="../../$source_root/$name"
    if [[ ! -L "$link" ]]; then
      fail "$link must be a symlink to $expected"
      continue
    fi
    actual="$(readlink "$link")"
    if [[ "$actual" != "$expected" ]]; then
      fail "$link points to '$actual'; expected '$expected'"
    fi
  done

  for link in "$link_root"/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      ../../"$source_root"/*)
        if [[ ! -d "$link_root/$target" ]]; then
          fail "$link points to a missing skill '$target'"
        fi
        ;;
    esac
  done
fi

if [[ "$failures" -ne 0 ]]; then
  printf 'Claude skill link guardrails failed with %d error(s).\n' "$failures" >&2
  exit 1
fi
printf 'OK: Claude skill link guardrails passed (%d skills linked).\n' "$(find "$source_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
