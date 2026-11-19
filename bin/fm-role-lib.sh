#!/usr/bin/env bash
# fm-role-lib.sh - the Firstmate home role and self-repository publication consent.
#
# Every Firstmate home runs as a user/operator by default: it may consume
# firstmate, change its gitignored operational state, and repair the installation
# locally, but nothing it does publishes to the firstmate repository's upstream.
# Upstream publication - a pushed branch, pull request, issue, comment, or fork -
# requires an explicit, home-local grant: the maintainer opt-in written by the
# operator into config/firstmate-role, or a bounded per-task consent recorded at
# dispatch. Role is never inferred from gh identity, permissions, remotes,
# environment, or CI. docs/configuration.md "Firstmate role" owns the
# operator-facing schema; this library owns parsing, repository-identity
# normalization, self-repository detection, and the fail-closed gate the dispatch
# surfaces share. Everything here resolves from files and local git plumbing
# only; nothing calls gh or the network.
#
# Role file: one directive line in config/firstmate-role (blank lines and
# full-line # comments ignored), either
#   user                                 - the default; may be omitted
#   maintainer <host>/<owner>/<repo>     - this home develops firstmate for the
#                                          named upstream
# A scope names the publication target repository (where a PR lands), not a push
# destination. In a secondmate home (marked by .fm-secondmate-home) a role file
# authorizes nothing on its own: it is trusted only when the existing
# config-inheritance receipt config/.fm-inherit-firstmate-role.generation proves
# the exact bytes the parent last published there, so a stale or unproven grant
# is dead on arrival. The parent publishes its resolved role
# (fm_role_inherit_payload), never its raw file, so a child never gains through
# supported propagation a grant the parent does not resolve. The receipt proves
# consistency, not provenance: it prevents accidental publication through
# supported paths and is not a security boundary against a process that
# deliberately forges local records.
#
# Self-repository detection compares the task's project dir against the running
# code root by repository lineage, offline: a shared git common dir covers
# linked worktrees and the code root itself, and a project holding a root commit
# of the code root's history covers any fork, the parent, and any clone of
# either. Lineage that cannot be determined (no code root history, or a shallow
# side sharing no root) refuses rather than permits. The publication target is
# compared only against a maintainer scope or task consent: the first remote
# whose remote.<name>.gh-resolved is base names that remote's repository, and an
# explicit owner/repo value names that repository on the remote's host, both
# following gh repo set-default; otherwise the first remote named
# upstream, github, or origin, reduced to lowercase host/owner/repo; a local-path remote
# is resolved one hop through that repository's own origin, and left as
# path:<abs> when unreadable. An unknown target never permits.
#
# Public functions:
#   fm_role_file <config-dir>            - the role file path
#   fm_role_scope_valid <scope>          - host/owner/repo[/subgroup] shape check
#   fm_role_scope_norm <scope>           - canonical comparison form
#   fm_role_remote_identity <url> [<dir>]- host/owner/repo or path:<abs> or empty
#   fm_role_publication_target <git-dir> - identity a default publication reaches
#   fm_role_self_repo <project> <root>   - 0 firstmate lineage, 1 not, 2 unknown
#   fm_role_parse_file <file>            - sets FM_ROLE/FM_ROLE_SCOPE/FM_ROLE_DIAG
#   fm_role_resolve <home> <config-dir>  - effective role; adds FM_ROLE_SOURCE
#   fm_role_inherit_payload <home> <config-dir> <out-file>
#                                        - stage the resolved role a parent publishes
#   fm_role_gate_self_publish <home> <config> <project> <root> [consent]
#                                        - 0 authorized, 1 refused, 2 not self-repo
#
# Global outputs: FM_ROLE (user|maintainer), FM_ROLE_SCOPE (maintainer scope),
# FM_ROLE_SOURCE (absent|local|inherited), FM_ROLE_DIAG (narrow refusal or
# malformed-input reason), FM_ROLE_PUB_TARGET, FM_ROLE_PUB_AUTHORITY,
# FM_ROLE_PUB_DENIAL.

# fm_role_file <config-dir>
fm_role_file() {
  printf '%s/firstmate-role\n' "${1%/}"
}

# fm_role_scope_valid <scope> - 0 when <scope> is <host>/<owner>/<repo>
# (deeper paths allowed for group-style hosts) over a conservative charset.
fm_role_scope_valid() {
  case $1 in
  */*/*) ;;
  *) return 1 ;;
  esac
  case $1 in
  *[!A-Za-z0-9._/-]* | .* | */ | *//* | *..*) return 1 ;;
  esac
  return 0
}

# fm_role_scope_norm <scope> - canonical comparison form.
fm_role_scope_norm() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# fm_role_abs_norm <path> - physical path when it exists, else a lexical
# collapse of . and .. so a not-yet-existing path still compares determinably.
fm_role_abs_norm() {
  local p=$1 seg out=
  if [ -d "$p" ]; then
    (CDPATH='' cd -- "$p" && pwd -P)
    return
  fi
  case $p in
  /*) ;;
  *) printf '%s\n' "$p"; return ;;
  esac
  local oldifs=$IFS
  IFS='/'
  set -f
  for seg in $p; do
    case $seg in
    '' | .) ;;
    ..) out=${out%/*} ;;
    *) out=$out/$seg ;;
    esac
  done
  IFS=$oldifs
  set +f
  printf '%s\n' "${out:-/}"
}

# fm_role_local_identity <path> [<base-dir>] - a local-path remote resolves one
# hop through that repository's own origin; unreadable or origin-less targets
# stay path:<absolute>. The hop is never transitive: a local origin there is
# itself reported as path:<absolute>, which keeps mutually-referencing local
# clones from resolving each other forever.
fm_role_local_identity() {
  local p=$1 base=${2:-} abs inner
  case $p in
  \~/*) p=$HOME/${p#\~/} ;;
  esac
  case $p in
  /*) abs=$p ;;
  *) abs=${base:+$base/}$p ;;
  esac
  abs=$(fm_role_abs_norm "$abs")
  if inner=$(git -C "$abs" remote get-url origin 2>/dev/null) && [ -n "$inner" ]; then
    fm_role_remote_identity "$inner" "$abs" nolocal
    return
  fi
  printf 'path:%s\n' "$abs"
}

# fm_role_path_identity <path> [<base-dir>] - path:<absolute> for a local-path
# remote with no further resolution (the nolocal reporting form).
fm_role_path_identity() {
  local p=$1 base=${2:-} abs
  case $p in
  /*) abs=$p ;;
  *) abs=${base:+$base/}$p ;;
  esac
  printf 'path:%s\n' "$(fm_role_abs_norm "$abs")"
}

# fm_role_remote_identity <url> [<base-dir>] [<nolocal>] - normalize a remote
# URL to lowercase host/owner/repo. scheme://[user@]host[:port]/owner/repo and
# [user@]host:owner/repo both reduce; .git suffixes drop; a local-path remote
# (absolute, relative, or file://) resolves through fm_role_local_identity,
# except under nolocal, where it reports path:<absolute> directly.
fm_role_remote_identity() {
  local url=$1 base=${2:-} nolocal=${3:-} rest host path
  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || return 0
  case $url in
  file://*)
    if [ -n "$nolocal" ]; then
      fm_role_path_identity "${url#file://}" "$base"
    else
      fm_role_local_identity "${url#file://}" "$base"
    fi
    ;;
  *://*)
    rest=${url#*://}
    rest=${rest%%[?#]*}
    host=${rest%%/*}
    [ "$host" = "$rest" ] && return 0
    host=${host#*@}
    host=${host%%:*}
    path=${rest#*/}
    path=${path%"${path##*[!/]}"}
    path=${path%.git}
    [ -n "$host" ] && [ -n "$path" ] || return 0
    printf '%s/%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    ;;
  *:*)
    # scp-style [user@]host:owner/repo
    host=${url%%:*}
    path=${url#*:}
    case $host in
    *[!A-Za-z0-9._@/-]* | */*)
      if [ -n "$nolocal" ]; then
        fm_role_path_identity "$url" "$base"
      else
        fm_role_local_identity "$url" "$base"
      fi
      return
      ;;
    esac
    host=${host#*@}
    path=${path%"${path##*[!/]}"}
    path=${path%.git}
    [ -n "$host" ] && [ -n "$path" ] || return 0
    printf '%s/%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    ;;
  *)
    if [ -n "$nolocal" ]; then
      fm_role_path_identity "$url" "$base"
    else
      fm_role_local_identity "$url" "$base"
    fi
    ;;
  esac
}

# fm_role_git_common_dir <dir> - physical common git dir or empty.
fm_role_git_common_dir() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  (CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) || printf '%s\n' "$common"
}


# fm_role_publication_target <git-dir> - the repository a default publication (gh pr/issue, a no-mistakes PR) would reach: the first remote whose remote.<name>.gh-resolved is base names that remote's repository, and an explicit owner/repo value names that repository on the remote's host, both following gh repo set-default; otherwise the first configured upstream, github, or origin, normalized to host/owner/repo or path:<abs>. Empty when the selected remote is unreadable or the repo has no such remote. Resolution is entirely offline.
fm_role_publication_target() {
  local dir=$1 remote remotes url='' value id
  remotes=$(git -C "$dir" remote 2>/dev/null) || return 0
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    value=$(git -C "$dir" config --get "remote.$remote.gh-resolved" 2>/dev/null) || continue
    case $value in
      base)
        url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || return 0
        fm_role_remote_identity "$url" "$dir"
        return
        ;;
      */*)
        case $value in
          */*/*|*\ *) continue ;;
        esac
        url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || return 0
        id=$(fm_role_remote_identity "$url" "$dir")
        case $id in
          ''|path:*) return 0 ;;
        esac
        fm_role_remote_identity "https://${id%%/*}/$value" "$dir"
        return
        ;;
    esac
  done <<< "$remotes"
  for remote in upstream github origin; do
    if url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) && [ -n "$url" ]; then
      break
    fi
    url=
  done
  [ -n "$url" ] || return 0
  fm_role_remote_identity "$url" "$dir"
}

# fm_role_shallow <dir> - 0 when <dir> is a shallow git repository.
fm_role_shallow() {
  [ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" = true ]
}

# fm_role_self_repo <project-dir> <code-root> - rc 0 when the task's project
# shares firstmate's lineage: a shared git common dir (the code root itself or
# a linked worktree of it), or a project holding a root commit of the code
# root's history. rc 1 when the project is not a git repository or provably
# shares no root. rc 2 when lineage cannot be determined: the code root has no
# history, or either side is shallow and no root matched. Offline only; lazy
# fetching of missing objects is disabled.
fm_role_self_repo() {
  local proj=$1 root=$2 pa pb roots c
  pa=$(fm_role_git_common_dir "$proj")
  [ -n "$pa" ] || return 1
  pb=$(fm_role_git_common_dir "$root")
  [ -n "$pb" ] && [ "$pa" = "$pb" ] && return 0
  roots=$(git -C "$root" rev-list --max-parents=0 HEAD 2>/dev/null) || roots=
  [ -n "$roots" ] || return 2
  for c in $roots; do
    GIT_NO_LAZY_FETCH=1 git -C "$proj" cat-file -e "$c^{commit}" 2>/dev/null && return 0
  done
  if fm_role_shallow "$root" || fm_role_shallow "$proj"; then
    return 2
  fi
  return 1
}

# fm_role_parse_file <file> - parse one role file. Sets FM_ROLE, FM_ROLE_SCOPE,
# FM_ROLE_DIAG. rc 0 valid; rc 1 malformed; rc 2 absent (missing or not a file).
# The whole file is read before any role is accepted, so a second directive
# anywhere makes it malformed.
fm_role_parse_file() {
  local file=$1 line directive=
  FM_ROLE=
  FM_ROLE_SCOPE=
  FM_ROLE_DIAG=
  if [ -L "$file" ]; then
    FM_ROLE_DIAG="role file must not be a symlink"
    return 1
  fi
  if [ ! -f "$file" ]; then
    FM_ROLE_DIAG="role file is missing"
    return 2
  fi
  if [ ! -r "$file" ]; then
    FM_ROLE_DIAG="role file is unreadable"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
    '' | '#'*) continue ;;
    esac
    if [ -n "$directive" ]; then
      FM_ROLE_DIAG="role file must hold exactly one directive line"
      return 1
    fi
    directive=$line
  done <"$file"
  if [ -z "$directive" ]; then
    FM_ROLE_DIAG="role file holds no directive"
    return 1
  fi
  set -f
  # shellcheck disable=SC2086  # directive tokens are intentionally word-split
  set -- $directive
  set +f
  case $1 in
  user)
    if [ "$#" -ne 1 ]; then
      FM_ROLE_DIAG="the user role takes no repository scope"
      return 1
    fi
    FM_ROLE=user
    ;;
  maintainer)
    if [ "$#" -ne 2 ]; then
      FM_ROLE_DIAG="the maintainer role requires exactly one repository scope"
      return 1
    fi
    if ! fm_role_scope_valid "$2"; then
      FM_ROLE_DIAG="invalid repository scope '$2'"
      return 1
    fi
    FM_ROLE=maintainer
    FM_ROLE_SCOPE=$(fm_role_scope_norm "$2")
    ;;
  *)
    FM_ROLE_DIAG="unknown role '$1' (expected user or maintainer)"
    return 1
    ;;
  esac
  return 0
}

# fm_role_sha256_stdin - hex digest of stdin on either digest tool.
# FM_ROLE_DIAG. A secondmate home (its .fm-secondmate-home marker) requires the
# inheritance receipt for any grant; a file it cannot prove is dead on arrival.
fm_role_resolve() {
  local config=$2 role_file
  FM_ROLE=user
  FM_ROLE_SCOPE=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_ROLE_SOURCE=absent
  FM_ROLE_DIAG=
  role_file=$(fm_role_file "$config")
  if [ -e "$role_file" ] || [ -L "$role_file" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ROLE_SOURCE=local
    if ! fm_role_parse_file "$role_file"; then
      FM_ROLE=user
      FM_ROLE_SCOPE=
      FM_ROLE_DIAG="malformed role file: $FM_ROLE_DIAG"
    fi
    return 0
  fi
  return 0
}

# fm_role_gate_self_publish <home> <config-dir> <project-dir> <code-root> [consent]
# Evaluate whether this home may run a publication contract for a task on
# firstmate's own repository. rc 0 authorized (FM_ROLE_PUB_AUTHORITY names the
# source: maintainer scope or task consent); rc 1 refused (FM_ROLE_PUB_DENIAL
# names the narrow reason); rc 2 the task is not on this firstmate repository
# and the boundary does not apply. FM_ROLE_PUB_TARGET is the normalized
# publication target when determinable.
fm_role_gate_self_publish() {
  local home=$1 config=$2 proj=$3 root=$4 consent=${5:-} lineage=0
  FM_ROLE_PUB_TARGET=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_ROLE_PUB_AUTHORITY=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_ROLE_PUB_DENIAL=
  fm_role_self_repo "$proj" "$root" || lineage=$?
  if [ "$lineage" -eq 1 ]; then
    return 2
  fi
  FM_ROLE_PUB_TARGET=$(fm_role_publication_target "$proj")
  if [ "$lineage" -eq 2 ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ROLE_PUB_DENIAL="cannot determine whether $proj shares firstmate's history (the code root $root has no readable history, or a shallow clone shares no root commit); fetch full history (git fetch --unshallow) before dispatching publishing work"
    return 1
  fi
  fm_role_resolve "$home" "$config"
  if [ -n "$consent" ]; then
    consent=$(fm_role_scope_norm "$consent")
    if ! fm_role_scope_valid "$consent"; then
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      FM_ROLE_PUB_DENIAL="upstream consent '$consent' is not a valid <host>/<owner>/<repo> scope"
      return 1
    fi
  fi
  if [ -z "$FM_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ROLE_PUB_DENIAL="this task targets firstmate's own repository but no publication target can be determined (no upstream, github, or origin remote on $proj)"
    return 1
  fi
  if [ -n "$consent" ] && [ "$consent" = "$FM_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ROLE_PUB_AUTHORITY="task consent for $consent"
    return 0
  fi
  if [ "$FM_ROLE" = maintainer ] && [ "$FM_ROLE_SCOPE" = "$FM_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ROLE_PUB_AUTHORITY="maintainer scope $FM_ROLE_PUB_TARGET"
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_ROLE_PUB_DENIAL="this home runs as firstmate user/operator and holds no publication authority for $FM_ROLE_PUB_TARGET"
  return 1
}
