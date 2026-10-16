#!/usr/bin/env bash
# Install per-task git hooks for a fleet launch, and run the commit parts.
#
set -u
unset CDPATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-strip-ai-trailers.sh <msgfile> | guard-commit | guard-push <name> <url>
  fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree> [--keep-trailers]
EOF
  exit 2
}

trim_space() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# True when this line is an AI Co-Authored-By trailer that must not reach a
# commit object. Matches known product names and exact observed bot addresses only; an
# address is added when a runtime is seen emitting it, never guessed from a
# vendor domain, so a human co-author who works at a vendor is kept. A human
# whose name or address merely contains a substring such as "ai" is kept.
fm_is_ai_attribution_line() {
  local raw=$1 lowered rest name email
  raw=${raw%$'\r'}
  raw=$(trim_space "$raw")
  [ -n "$raw" ] || return 1
  lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
  co-authored-by:*) ;;
  *) return 1 ;;
  esac
  rest=$(trim_space "${raw#*:}")
  name=$rest
  email=
  case "$rest" in
  *'<'*'>'*)
    email=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
    email=${email#*'<'}
    email=${email%%'>'*}
    name=$(trim_space "${rest%%'<'*}")
    ;;
  esac
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$email" in
  noreply@anthropic.com | cursoragent@* | noreply@openai.com | copilot@github.com)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai)
    return 0
    ;;
  esac
  return 1
}

strip_msgfile() {
  local src=$1 tmp
  [ -f "$src" ] || {
    echo "error: commit message file not found: $src" >&2
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-git-strip-ai-trailers.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if fm_is_ai_attribution_line "$line"; then
      continue
    fi
    printf '%s\n' "$line"
  done <"$src" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$src"
}

quote_for_hook() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_executable() {
  local dest=$1
  cat >"$dest" || return 1
  chmod 500 "$dest"
}

split_ident() {
  local ident=$1 name rest email
  case "$ident" in
  *'<'*'>'*) ;;
  *) return 1 ;;
  esac
  name=${ident%% <*}
  rest=${ident#*<}
  email=${rest%%>*}
  [ -n "$name" ] && [ -n "$email" ] && [ "$name" != "$ident" ] || return 1
  printf '%s\n%s\n' "$name" "$email"
}

# The pane GIT_CONFIG_* entries stay: they only point core.hooksPath here.
guard_reference() {
  local ident var=$1
  ident=$(unset GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; git var "$var" 2>/dev/null) || return 1
  split_ident "$ident"
}

# A foreign author or committer stops here instead of in CI.
guard_commit() {
  local var eff ref eff_name eff_email ref_name ref_email
  for var in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
    eff=$(git var "$var" 2>/dev/null) || {
      echo "fm-git-strip-ai-trailers: refusing commit: git cannot resolve $var here" >&2
      return 1
    }
    eff=$(split_ident "$eff") || {
      echo "fm-git-strip-ai-trailers: refusing commit: git resolved an unreadable $var" >&2
      return 1
    }
    eff_name=${eff%%$'\n'*}
    eff_email=${eff#*$'\n'}
    ref=$(guard_reference "$var") || {
      echo "fm-git-strip-ai-trailers: refusing commit: no user.name or user.email in this machine's git config files (git config user.name and user.email)" >&2
      return 1
    }
    ref_name=${ref%%$'\n'*}
    ref_email=${ref#*$'\n'}
    if [ "$eff_name" != "$ref_name" ] || [ "$eff_email" != "$ref_email" ]; then
      echo "fm-git-strip-ai-trailers: refusing commit with an author or committer that differs from this machine's git config files (git config user.name and user.email)" >&2
      echo "fm-git-strip-ai-trailers: commit with the configured identity instead of -c user.name, --author, or GIT_AUTHOR_* and GIT_COMMITTER_* overrides" >&2
      return 1
    fi
  done
}

# Amend and rebase replay commits past the commit-time hook, so the pushed range is checked here.
guard_push() {
  local ref_a ref_c ref_an ref_ae ref_cn ref_ce
  local local_ref local_sha remote_ref remote_sha extra
  ref_a=$(guard_reference GIT_AUTHOR_IDENT) || {
    echo "fm-git-strip-ai-trailers: refusing push: no user.name or user.email in this machine's git config files (git config user.name and user.email)" >&2
    return 1
  }
  ref_c=$(guard_reference GIT_COMMITTER_IDENT) || {
    echo "fm-git-strip-ai-trailers: refusing push: no user.name or user.email in this machine's git config files (git config user.name and user.email)" >&2
    return 1
  }
  ref_an=${ref_a%%$'\n'*}
  ref_ae=${ref_a#*$'\n'}
  ref_cn=${ref_c%%$'\n'*}
  ref_ce=${ref_c#*$'\n'}
  while read -r local_ref local_sha remote_ref remote_sha extra; do
    [ -n "$local_ref" ] || continue
    if [ -z "$local_sha" ] || [ -z "$remote_ref" ] || [ -z "$remote_sha" ] || [ -n "$extra" ]; then
      echo "fm-git-strip-ai-trailers: refusing push: unreadable pre-push input" >&2
      return 1
    fi
    case "$local_sha" in
    *[!0]*) ;;
    *) continue ;;
    esac
    guard_push_range "$local_sha" "$remote_sha" "$ref_an" "$ref_ae" "$ref_cn" "$ref_ce" || return 1
  done
}

guard_push_range() {
  local local_sha=$1 remote_sha=$2 ref_an=$3 ref_ae=$4 ref_cn=$5 ref_ce=$6
  local lines excludes line sha an ae cn ce extra short
  case "$remote_sha" in
  *[!0]*)
    lines=$(git log --format='%H%x1f%an%x1f%ae%x1f%cn%x1f%ce' "$remote_sha..$local_sha" 2>/dev/null) || {
      echo "fm-git-strip-ai-trailers: refusing push: cannot list the pushed range" >&2
      return 1
    }
    ;;
  *)
    excludes=$(git for-each-ref --format='%(objectname)' refs/remotes/ 2>/dev/null) || {
      echo "fm-git-strip-ai-trailers: refusing push: cannot list the remote refs" >&2
      return 1
    }
    if [ -z "$excludes" ]; then
      lines=$(git log --format='%H%x1f%an%x1f%ae%x1f%cn%x1f%ce' "$local_sha" 2>/dev/null) || {
        echo "fm-git-strip-ai-trailers: refusing push: cannot list the pushed range" >&2
        return 1
      }
    else
      # shellcheck disable=SC2086
      lines=$(git log --format='%H%x1f%an%x1f%ae%x1f%cn%x1f%ce' "$local_sha" --not $excludes 2>/dev/null) || {
        echo "fm-git-strip-ai-trailers: refusing push: cannot list the pushed range" >&2
        return 1
      }
    fi
    ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\x1f' read -r sha an ae cn ce extra <<< "$line"
    if [ -z "$sha" ] || [ -z "$an" ] || [ -z "$ae" ] || [ -z "$cn" ] || [ -z "$ce" ] || [ -n "$extra" ]; then
      echo "fm-git-strip-ai-trailers: refusing push: cannot read a pushed commit's identity" >&2
      return 1
    fi
    if [ "$an" != "$ref_an" ] || [ "$ae" != "$ref_ae" ] || [ "$cn" != "$ref_cn" ] || [ "$ce" != "$ref_ce" ]; then
      short=$(git rev-parse --short "$sha" 2>/dev/null) || short=$sha
      echo "fm-git-strip-ai-trailers: refusing push with commit $short whose author or committer differs from this machine's git config files (git config user.name and user.email)" >&2
      echo "fm-git-strip-ai-trailers: push only commits with the configured identity" >&2
      return 1
    fi
  done <<< "$lines"
}

# Shared body for every wrapper: after the pane-wide GIT_CONFIG override is
# cleared, resolve this repository's own hooks directory the way git does
# (core.hooksPath, else the common dir's hooks) and exec that name if it
# exists. The lookup runs without GIT_CONFIG_PARAMETERS as well, since git -c
# is the other environment channel that can carry this directory as
# core.hooksPath; only the repository's config files name its own hooks. Skip
# when the lookup still names this launch's own hooks dir, meaning those files
# point here, so the wrapper cannot recurse into itself. An empty
# core.hooksPath makes that lookup fail, but plain git reads it as "no hooks",
# so the wrapper runs none; any other failure reruns the lookup to show git's
# error and refuses.
runtime_chain_body() {
  local ours=$1
  cat <<EOF
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
ours=$(quote_for_hook "$ours")
name=\${0##*/}
orig=\$(unset GIT_CONFIG_PARAMETERS; git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || {
  if hooks_path=\$(unset GIT_CONFIG_PARAMETERS; git config --get --type=path core.hooksPath 2>/dev/null) && [ -z "\$hooks_path" ]; then
    exit 0
  fi
  (unset GIT_CONFIG_PARAMETERS; git rev-parse --path-format=absolute --git-path hooks >/dev/null)
  echo "fm-git-strip-ai-trailers: cannot resolve this repository's hooks directory; refusing to skip its \$name hook" >&2
  exit 1
}
if [ "\$orig" = "\$ours" ]; then
  exit 0
fi
if [ -x "\$orig/\$name" ]; then
  exec "\$orig/\$name" "\$@"
fi
EOF
}

# Client-side hook names git invokes by name from core.hooksPath, per
# githooks(5) in git 2.50. The receive-side names, the config-invoked
# fsmonitor-watchman, and the git-p4 names are left out because git never looks
# them up in a fleet worker's own worktree. commit-msg is written separately
# because it is the one that carries the strip.
#
# reference-transaction and post-index-change are deliberately excluded, ruled
# 2026-09-17. git invokes them twice per updated ref and on every index write,
# so a wrapper for either turns a stat git used to skip into hundreds of forks
# on one bulk command. Measured on git 2.50.1: a fetch of 300 new refs goes
# 0.23s -> 24.6s, and a no-op /bin/sh hook still costs 4.9s, so the price is
# git's invocation rather than the wrapper body. Neither name is one
# commit-message or lint tooling installs, which is what this chaining exists
# to preserve. A project that does install one loses chaining for it inside
# fleet panes only.
#
# The names kept are not free either, and that cost is accepted, ruled
# 2026-09-17. Every wrapper call forks bash plus one git rev-parse. A plain
# commit fires four wrappers, and git's sequencer fires prepare-commit-msg and
# post-commit once per replayed commit in rebase and cherry-pick, as git am does
# its applypatch hooks per patch. Measured on git 2.50.1 with no project hooks:
# one commit goes ~76ms -> ~276ms, and a 60-commit rebase 0.74s -> 3.7s. They
# stay because git-lfs installs post-commit, post-checkout, post-merge and
# pre-push, and a slower rebase inside a pane is the accepted price.
FM_GIT_CLIENT_HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit
pre-merge-commit prepare-commit-msg post-commit pre-rebase post-checkout
post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'

install_hooks() {
  local hooks_dir=$1 wt=$2 strip=1 name
  [ -n "$hooks_dir" ] && [ -n "$wt" ] || usage
  case "${3:-}" in
  ''|--strip) strip=1 ;;
  --keep-trailers) strip=0 ;;
  *) usage ;;
  esac
  [ -d "$wt" ] || {
    echo "error: worktree is not a directory: $wt" >&2
    return 1
  }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null || {
    echo "error: not a git worktree: $wt" >&2
    return 1
  }
  chmod u+w "$hooks_dir" 2>/dev/null
  rm -rf "$hooks_dir"
  mkdir -p "$hooks_dir" || return 1
  chmod 700 "$hooks_dir" 2>/dev/null || true
  hooks_dir=$(CDPATH='' cd -- "$hooks_dir" && pwd -P) || return 1

  if [ "$strip" = 1 ]; then
    write_executable "$hooks_dir/commit-msg" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") "\$1" || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF
  else
    write_executable "$hooks_dir/commit-msg" <<EOF
#!/usr/bin/env bash
set -u
$(runtime_chain_body "$hooks_dir")
EOF
  fi

  write_executable "$hooks_dir/pre-commit" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") guard-commit || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF

  write_executable "$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") guard-push "\$@" || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF

  for name in $FM_GIT_CLIENT_HOOKS; do
    case "$name" in
    pre-commit|pre-push) continue ;;
    esac
    write_executable "$hooks_dir/$name" <<EOF
#!/usr/bin/env bash
set -u
$(runtime_chain_body "$hooks_dir")
EOF
  done
  chmod 500 "$hooks_dir"
}

CMD=${1:-}
case "$CMD" in
install)
  case "$#" in
  3) install_hooks "$2" "$3" ;;
  4) install_hooks "$2" "$3" "$4" ;;
  *) usage ;;
  esac
  ;;
guard-commit)
  [ "$#" -eq 1 ] || usage
  guard_commit
  ;;
guard-push)
  [ "$#" -eq 3 ] || usage
  guard_push
  ;;
-h | --help)
  usage
  ;;
'')
  usage
  ;;
*)
  if [ "$CMD" = "${CMD#-}" ] && [ "$#" -ge 1 ]; then
    strip_msgfile "$1"
  else
    usage
  fi
  ;;
esac
