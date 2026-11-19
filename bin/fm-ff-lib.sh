# shellcheck shell=bash
# Fast-forward one clean checkout on its default branch.

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md imports via @AGENTS.md), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

# Prove that a content-level merge of LOCAL into TARGET is clean and yields
# exactly TARGET's tree, so moving to TARGET discards nothing. A trivial
# read-tree three-way leaves any file edited on both lines unmerged even when
# TARGET already holds the local edit. merge-tree --write-tree writes only
# objects, never the worktree or a ref; a git without it fails here, which
# refuses the divergence.
divergence_is_redundant() { # <dir> <local-commit> <target-commit>
  local dir=$1 local_commit=$2 target_commit=$3 merged_tree target_tree
  target_tree=$(git -C "$dir" rev-parse --verify --quiet "$target_commit^{tree}" 2>/dev/null) || return 1
  merged_tree=$(git -C "$dir" merge-tree --write-tree "$target_commit" "$local_commit" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ -n "$target_tree" ] && [ "$merged_tree" = "$target_tree" ]
}

FF_STATUS=""
FF_INSTR=""
ff_target_instructions_changed() { [ -n "$FF_INSTR" ]; }
ff_target_updated() { [ "$FF_STATUS" = updated ]; }
ff_target() {
  local dir=$1 label=$2 base_mode=$3 reconcile_redundant=${4:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi
  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    if [ "$reconcile_redundant" = yes ] \
      && divergence_is_redundant "$dir" "$local_rev" "$base_rev"; then
      instr=$(changed_instr "$dir" "$base")
      before=$(git -C "$dir" rev-parse --short HEAD)
      if git -C "$dir" reset --keep "$base" >/dev/null 2>&1; then
        after=$(git -C "$dir" rev-parse --short HEAD)
        FF_STATUS="updated"
        FF_INSTR=$instr
        if [ -n "$instr" ]; then
          echo "$label: reconciled redundant divergence $before..$after (instructions changed: $instr)"
        else
          echo "$label: reconciled redundant divergence $before..$after"
        fi
        return 0
      fi
      echo "$label: skipped: redundant divergence could not be reconciled with reset --keep"
      return 0
    fi
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR=$instr
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}
