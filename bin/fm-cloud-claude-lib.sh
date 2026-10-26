#!/usr/bin/env bash
# fm-cloud-claude-lib.sh - the launch rules bin/fm-spawn.sh applies to a cloud-claude worker.

FM_CLOUD_CLAUDE_DEADLINE_DEFAULT=90

# Claude Code cloud sessions clone from github.com only.
fm_cloud_github_repo() {  # <origin-url> -> owner/repo
  local url=$1 path
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ $path =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "$path"
}

# Read raw rather than through git remote get-url: the cloud session clones the
# configured remote, never this host's url.*.insteadOf rewrite of it.
fm_cloud_origin_url() {  # <git-dir>
  git -C "$1" config --get remote.origin.url 2>/dev/null
}

fm_cloud_config_word() {  # <file>
  [ -f "$1" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$' | head -n 1
}

fm_cloud_claude_account() {  # <config-dir> <explicit-account> -> clauth profile
  local config=$1 explicit=$2 account
  account=${explicit:-$(fm_cloud_config_word "$config/cloud-claude-account")}
  [ -n "$account" ] || {
    echo "error: harness cloud-claude needs the credit-backed Claude account: write its config/claude-accounts profile name to $config/cloud-claude-account, or pass --claude-account <profile>" >&2
    return 1
  }
  printf '%s\n' "$account"
}

fm_cloud_claude_deadline_minutes() {  # <config-dir>
  local value
  value=$(fm_cloud_config_word "$1/cloud-claude-deadline")
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$FM_CLOUD_CLAUDE_DEADLINE_DEFAULT" ;;
    *)
      value=$((10#$value))
      [ "$value" -gt 0 ] || value=$FM_CLOUD_CLAUDE_DEADLINE_DEFAULT
      printf '%s\n' "$value"
      ;;
  esac
}

# no-mistakes runs on this machine and local-only never reaches GitHub, so only
# a direct-PR ship qualifies.
fm_cloud_claude_validate_launch() {  # <kind> <mode> <raw-launch 0|1> <model> <effort>
  local kind=$1 mode=$2 raw=$3 model=$4 effort=$5
  [ "$raw" = 0 ] || {
    echo "error: harness cloud-claude has no raw launch form; pass --harness cloud-claude" >&2
    return 1
  }
  [ "$kind" = ship ] || {
    echo "error: harness cloud-claude runs ship tasks only; a $kind task stays on a local harness" >&2
    return 1
  }
  [ "$mode" = direct-PR ] || {
    echo "error: harness cloud-claude needs --mode direct-PR; mode=${mode:-unset} runs on this machine (no-mistakes) or never reaches GitHub (local-only), so it stays on a local harness" >&2
    return 1
  }
  local axis
  for axis in "$model" "$effort"; do
    case "$axis" in
      ''|default) ;;
      *)
        echo "error: harness cloud-claude runs the cloud session's own model and effort; omit --model and --effort" >&2
        return 1
        ;;
    esac
  done
}

fm_cloud_claude_validate_project() {  # <forge> <origin-url>
  local forge=$1 origin=$2
  case "$forge" in
    ''|none) ;;
    *)
      echo "error: harness cloud-claude publishes GitHub pull requests only; this project is registered forge=$forge" >&2
      return 1
      ;;
  esac
  fm_cloud_github_repo "$origin" >/dev/null || {
    echo "error: harness cloud-claude needs a project whose origin is on github.com; origin is '${origin:-unset}'" >&2
    return 1
  }
}
