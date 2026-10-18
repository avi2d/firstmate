#!/usr/bin/env bash
# Install per-task git hooks for a fleet launch, and run the commit parts.
#
# Usage:
#   fm-git-strip-ai-trailers.sh <msgfile>
#       Commit-msg hook mode. Git passes the proposed message file as $1.
#       Rewrites that file in place, then exits 0 so the commit proceeds.
#   fm-git-strip-ai-trailers.sh install [--no-strip] [--push-guard <guard-file>] <hooks-dir> <worktree>
#       Recreate <hooks-dir> as a core.hooksPath for this launch: a commit-msg
#       hook that runs this strip, plus one wrapper per client-side hook name
#       git documents except reference-transaction and post-index-change,
#       which are deliberately excluded (see FM_GIT_CLIENT_HOOKS below).
#       Each wrapper removes this directory's own core.hooksPath entry from
#       GIT_CONFIG_*, keeping every inherited entry (a scoped credential.helper,
#       safe.directory) for the repository's hook, and then resolves
#       core.hooksPath (or $GIT_DIR/hooks) in the repository git is actually
#       running in, so a husky directory that only appears after npm install
#       still runs, and git -C some-other-repo does not inherit the task
#       worktree's hooks. That lookup also ignores GIT_CONFIG_PARAMETERS,
#       because git -c core.hooksPath=<this dir> (or a child process that
#       inherits it) carries the override there, and a lookup that honored it
#       would find this directory again and never run the repository's own
#       hook - a skipped pre-push guard. An empty core.hooksPath means no
#       repository hook, as in plain git; any other failed lookup exits
#       nonzero rather than skipping the repository's hook. Does not touch the
#       project's git config; the caller prefixes the pane with env-file below.
#       --no-strip writes a commit-msg wrapper that only chains, for a home that
#       keeps trailers but still needs the directory for the push guard.
#       --push-guard copies <guard-file> into <hooks-dir> read-only and makes
#       the pre-push wrapper run bin/fm-git-push-guard.sh on it first, with
#       git's arguments and ref lines, chaining to the repository's pre-push
#       hook only when the guard passes (that script owns the rules).
#   fm-git-strip-ai-trailers.sh env-file <hooks-dir> <out-file>
#       Write <out-file> as one plain export statement that appends
#       core.hooksPath=<hooks-dir> after the GIT_CONFIG_COUNT entries this
#       process inherited. The launch runs it in the pane and sources the
#       result, so the index comes from the environment the worker inherits
#       while the pane shell (fish included) only parses a simple command, &&,
#       || and an export list. A count that is not a decimal number, or that
#       leaves no room in git's signed-int count, exits nonzero with an error.
#
# WHY THIS EXISTS. Claude launches already carry attribution-off in their
# per-launch --settings JSON. Cursor and other non-Claude runtimes inject a
# Co-Authored-By trailer at the tooling layer AFTER the worker types a clean
# message, so the typed message is not the commit object.
# A prior per-machine ~/.cursor/cli-config.json attribution-off is not durable:
# it does not travel with Firstmate, it defaults back to on when unset, and it
# only feeds the CLI's request to the server - the trailer text is emitted by
# the model, so the setting suppresses rather than prevents it. Verified live
# on cursor-agent 2026.09.15 with attribution on: the trailer is already in
# .git/COMMIT_EDITMSG when the commit-msg hook runs, so the spawn-owned hook is
# the layer that sees the assembled message before the commit object is written.
# Command Code adds `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>`
# to worker commits by default (seen live on 1.74.1); only its settings files can
# turn that off, with no per-process switch, so this strip is its only layer.
# Human Co-Authored-By trailers are left untouched. Author identity is not
# rewritten.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. git commit --no-verify skips every hook,
# so a worker that passes it still lands the trailer, as would a runtime that
# writes the commit object without running git. Both incidents that motivated
# this strip came through an ordinary hook-running commit, so the ruling is to
# accept that gap rather than add a push-side rewrite or a push-side check. A
# trailer found on a fleet commit therefore points at one of those two paths,
# not at an unnoticed hole in the matcher.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. Inside a fleet pane git reports this
# directory as the repository's hooks directory, so a hook manager run there
# (lefthook's npm postinstall, pre-commit install) targets it and would
# displace the strip. install leaves the directory and every hook in it
# read-only, so such a manager fails loudly instead of silently winning. Hook
# managers therefore cannot install from inside fleet panes until a registered
# project genuinely needs it. Whoever removes the directory restores the owner
# write bit first.
set -u
unset CDPATH

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-strip-ai-trailers.sh <msgfile>
  fm-git-strip-ai-trailers.sh install [--no-strip] [--push-guard <guard-file>] <hooks-dir> <worktree>
  fm-git-strip-ai-trailers.sh env-file <hooks-dir> <out-file>
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
  noreply@anthropic.com | cursoragent@* | noreply@openai.com | copilot@github.com | noreply@commandcode.ai)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai | commandcodebot)
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
  excludes=$(git for-each-ref --format='%(objectname)' refs/remotes/ 2>/dev/null) || {
    echo "fm-git-strip-ai-trailers: refusing push: cannot list the remote refs" >&2
    return 1
  }
  # A merge of a tracked remote branch lands its commits inside the pushed range,
  # so every range excludes what any remote already holds and only new commits are checked.
  case "$remote_sha" in
  *[!0]*)
    if [ -z "$excludes" ]; then
      lines=$(git log --format='%H%x1f%an%x1f%ae%x1f%cn%x1f%ce' "$remote_sha..$local_sha" 2>/dev/null) || {
        echo "fm-git-strip-ai-trailers: refusing push: cannot list the pushed range" >&2
        return 1
      }
    else
      # shellcheck disable=SC2086
      lines=$(git log --format='%H%x1f%an%x1f%ae%x1f%cn%x1f%ce' "$local_sha" --not "$remote_sha" $excludes 2>/dev/null) || {
        echo "fm-git-strip-ai-trailers: refusing push: cannot list the pushed range" >&2
        return 1
      }
    fi
    ;;
  *)
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

# Shared body for every wrapper: after this directory's core.hooksPath entries
# are removed from GIT_CONFIG_* (later entries shift down, so inherited ones
# such as a scoped credential.helper still reach the repository's hook; a
# relaunch in the same pane can leave more than one), resolve this
# repository's own hooks directory the way git does (core.hooksPath, else the
# common dir's hooks) and exec that name if it exists. The lookup runs without GIT_CONFIG_PARAMETERS as well, since git -c
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
ours=$(quote_for_hook "$ours")
case \${GIT_CONFIG_COUNT:-} in
'' | *[!0-9]*) ;;
*)
  count=\$((10#\$GIT_CONFIG_COUNT)) i=0 kept=0
  while [ "\$i" -lt "\$count" ]; do
    key=GIT_CONFIG_KEY_\$i value=GIT_CONFIG_VALUE_\$i
    if [ "\${!key-}" != core.hooksPath ] || [ "\${!value-}" != "\$ours" ]; then
      [ "\$i" = "\$kept" ] || export "GIT_CONFIG_KEY_\$kept=\${!key-}" "GIT_CONFIG_VALUE_\$kept=\${!value-}"
      kept=\$((kept + 1))
    fi
    i=\$((i + 1))
  done
  export GIT_CONFIG_COUNT=\$kept
  ;;
esac
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

write_env_file() {
  local hooks_dir=$1 out=$2 count=${GIT_CONFIG_COUNT:-0} tmp
  [ -n "$hooks_dir" ] && [ -n "$out" ] || usage
  # Wrappers drop only an entry naming their own install path, which install
  # canonicalizes; write the same spelling so a symlinked path still matches.
  hooks_dir=$(CDPATH='' cd -- "$hooks_dir" 2>/dev/null && pwd -P) || {
    echo "error: cannot resolve hooks directory $1" >&2
    return 1
  }
  case "$count" in
  *[!0-9]*)
    echo "error: invalid inherited GIT_CONFIG_COUNT" >&2
    return 1
    ;;
  esac
  while [ "${count#0}" != "$count" ]; do count=${count#0}; done
  count=${count:-0}
  if [ "${#count}" -gt 10 ] || [ "$count" -ge 2147483647 ]; then
    echo "error: inherited GIT_CONFIG_COUNT cannot be extended" >&2
    return 1
  fi
  tmp=$(mktemp "$out.XXXXXX") || return 1
  if ! printf 'export GIT_CONFIG_KEY_%s=core.hooksPath GIT_CONFIG_VALUE_%s=%s GIT_CONFIG_COUNT=%s\n' \
    "$count" "$count" "$(quote_for_hook "$hooks_dir")" "$((count + 1))" >"$tmp" || ! mv -f "$tmp" "$out"; then
    rm -f "$tmp"
    return 1
  fi
}

install_hooks() {
  local hooks_dir=$1 wt=$2 strip=${3:-1} guard_src=${4:-} name strip_line guard_file guard_cmd
  [ -n "$hooks_dir" ] && [ -n "$wt" ] || usage
  if [ -n "$guard_src" ] && { [ ! -f "$guard_src" ] || [ ! -r "$guard_src" ]; }; then
    echo "error: push guard file is not a readable regular file: $guard_src" >&2
    return 1
  fi
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

  strip_line=
  [ "$strip" = 0 ] || strip_line="$(quote_for_hook "$SELF") \"\$1\" || exit \$?"
  write_executable "$hooks_dir/commit-msg" <<EOF
#!/usr/bin/env bash
set -u
$strip_line
$(runtime_chain_body "$hooks_dir")
EOF
  write_executable "$hooks_dir/pre-commit" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") guard-commit || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF

  # A push guard replaces this wrapper below, so an unconditional write would fail against its own read-only file.
  if [ -z "$guard_src" ]; then
    write_executable "$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") guard-push "\$@" || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF
  fi

  if [ -n "$guard_src" ]; then
    guard_file="$hooks_dir/fm-push-guard"
    { cp "$guard_src" "$guard_file" && chmod 400 "$guard_file"; } || return 1
    guard_cmd="$(quote_for_hook "${SELF%/*}/fm-git-push-guard.sh") $(quote_for_hook "$guard_file")"
    # git passes the refs being pushed on stdin; the guard reads them, so they
    # are captured once and replayed to the repository's own pre-push hook.
    write_executable "$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
set -u
refs=\$(cat)
if [ -n "\$refs" ]; then
  printf '%s\\n' "\$refs" | $guard_cmd "\$@" || exit 1
  exec 0<<<"\$refs"
else
  $guard_cmd "\$@" </dev/null || exit 1
  exec 0</dev/null
fi
$(runtime_chain_body "$hooks_dir")
EOF
  fi

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
  shift
  strip=1 guard=
  while [ "$#" -gt 2 ]; do
    case "$1" in
    --no-strip)
      strip=0
      shift
      ;;
    --push-guard)
      [ "$#" -gt 3 ] || usage
      guard=$2
      shift 2
      ;;
    *) usage ;;
    esac
  done
  [ "$#" -eq 2 ] || usage
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  install_hooks "$1" "$2" "$strip" "$guard"
  ;;
guard-commit)
  [ "$#" -eq 1 ] || usage
  guard_commit
  ;;
guard-push)
  [ "$#" -eq 3 ] || usage
  guard_push
  ;;
env-file)
  [ "$#" -eq 3 ] || usage
  write_env_file "$2" "$3"
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
