#!/usr/bin/env bash
# fm-agent-sandbox.sh: per-task nono sandbox for pi workers.
set -u

FM_AGENT_SANDBOX_PIN_DEFAULT="0.80.0"
FM_AGENT_SANDBOX_CONFIG_NAME="agent-sandbox"

fm_sandbox_config_file() { printf '%s/%s' "$1" "$FM_AGENT_SANDBOX_CONFIG_NAME"; }

fm_sandbox_enabled() {
  [ -e "$(fm_sandbox_config_file "$1")" ]
}

fm_sandbox_pin() {
  local file pin
  file=$(fm_sandbox_config_file "$1")
  pin=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" 2>/dev/null | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
  [ -n "$pin" ] || {
    echo "error: $file names no pinned nono version; write one line such as $FM_AGENT_SANDBOX_PIN_DEFAULT" >&2
    return 1
  }
  printf '%s\n' "$pin"
}

fm_sandbox_nono_version() {
  nono --version 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
}

fm_sandbox_check() {
  local pin have
  pin=$(fm_sandbox_pin "$1") || return 1
  command -v nono >/dev/null 2>&1 || {
    echo "error: config/$FM_AGENT_SANDBOX_CONFIG_NAME pins nono $pin but nono is not installed; refusing to launch unsandboxed" >&2
    return 1
  }
  have=$(fm_sandbox_nono_version)
  [ "$have" = "$pin" ] || {
    echo "error: config/$FM_AGENT_SANDBOX_CONFIG_NAME pins nono $pin but $have is installed; refusing to launch unsandboxed" >&2
    return 1
  }
}

fm_sandbox_model_route() {
  local model=${1:-}
  case "$model" in
  "" | default) printf 'unknown\n' ;;
  claude-bridge/*) printf 'claude\n' ;;
  opencode-go/*) printf 'proxy:opencode-go\n' ;;
  */*) printf 'unsupported:%s\n' "${model%%/*}" ;;
  *) printf 'unknown\n' ;;
  esac
}

fm_sandbox_claude_token_path() { printf '%s/agent-sandbox-claude-token' "$1"; }

fm_sandbox_render() {
  local state_real=$1 id=$2 worktree=$3 task_tmp=$4 data_id_dir=$5 hooks_dir=$6 fm_root=$7 kind=$8 mode=$9 route=${10:-proxy}
  local script_dir profile pi_dir capture_log pi_bin git_common git_dir sock
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  profile="$state_real/$id.nono.json"
  pi_dir="$task_tmp/pi-agent"
  capture_log="$task_tmp/nono-capture.log"
  pi_bin=$(command -v pi) || { echo "error: pi not found for sandbox capture wiring" >&2; return 1; }
  mkdir -p "$pi_dir" "$data_id_dir" "$state_real/$id.inbox/handled" "$task_tmp/gotmp" || return 1
  chmod 700 "$pi_dir" "$task_tmp" 2>/dev/null || true
  git_common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || git_common=
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=
  case "$git_common" in
  /*) ;;
  "" ) ;;
  *) git_common="$worktree/$git_common" ;;
  esac
  case "$git_dir" in
  /*) ;;
  "" ) ;;
  *) git_dir="$worktree/$git_dir" ;;
  esac
  sock="$HOME/.no-mistakes/socket"
  FM_SANDBOX_STATE_REAL=$state_real FM_SANDBOX_ID=$id FM_SANDBOX_WORKTREE=$worktree \
    FM_SANDBOX_TASK_TMP=$task_tmp FM_SANDBOX_DATA_ID=$data_id_dir FM_SANDBOX_HOOKS=$hooks_dir \
    FM_SANDBOX_ROOT=$fm_root FM_SANDBOX_KIND=$kind FM_SANDBOX_MODE=$mode \
    FM_SANDBOX_COMMON=$git_common FM_SANDBOX_GITDIR=$git_dir FM_SANDBOX_SOCK=$sock \
    FM_SANDBOX_CAPTURE="$script_dir/fm-agent-sandbox-capture.sh" FM_SANDBOX_ROUTE="$route" \
    python3 - <<'EOF'
import json, os
def env(name):
    value = os.environ.get(name, "")
    return value if value else None
state = os.environ["FM_SANDBOX_STATE_REAL"]
task = os.environ["FM_SANDBOX_ID"]
worktree = os.environ["FM_SANDBOX_WORKTREE"]
task_tmp = os.environ["FM_SANDBOX_TASK_TMP"]
data_id = os.environ["FM_SANDBOX_DATA_ID"]
hooks = env("FM_SANDBOX_HOOKS")
root = os.environ["FM_SANDBOX_ROOT"]
kind = os.environ["FM_SANDBOX_KIND"]
mode = os.environ["FM_SANDBOX_MODE"]
common = env("FM_SANDBOX_COMMON")
gitdir = env("FM_SANDBOX_GITDIR")
sock = env("FM_SANDBOX_SOCK")
route = os.environ.get("FM_SANDBOX_ROUTE", "proxy")
claude = (route == "claude")
allow = [worktree, task_tmp, task_tmp + "/pi-agent", data_id, state + "/" + task + ".inbox"]
read = [os.path.expanduser("~/.local/share/mise"), os.path.join(os.path.expanduser("~"), ".config/git"), root + "/bin"]
# The generated -e extension imports this directory at startup.
for candidate in (os.path.join(os.path.expanduser("~"), "Projects/example/home/.config/git"), os.path.join(os.path.expanduser("~"), "Projects/example"), root + "/.agents/skills", root + "/.pi/extensions/lib"):
    if os.path.exists(candidate):
        read.append(candidate)
if common and os.path.isdir(common):
    if kind == "ship":
        allow.append(common)
    else:
        read.append(common)
    for leaf in ("objects", "refs", "logs"):
        leaf_path = common + "/" + leaf
        if os.path.isdir(leaf_path):
            allow.append(leaf_path)
if gitdir and os.path.isdir(gitdir) and gitdir != common:
    allow.append(gitdir)
if hooks and os.path.isdir(hooks):
    read.append(hooks)
filesystem = {
    "allow": sorted(set(allow)),
    "read": sorted(set(read)),
    "allow_file": [state + "/" + task + ".status"] + ([gitdir] if gitdir and os.path.isfile(gitdir) else []),
    "read_file": [state + "/" + task + ".pi-ext.ts"],
    "write_file": [state + "/" + task + ".turn-ended", state + "/" + task + ".busy-state", state + "/" + task + ".busy-gen"],
    "write": ["/dev"],
    # No nono flag disables the save-profile review; "/" only mutes the offer, never grants.
    "suppress_save_prompt": ["/"],
}
if common and os.path.isfile(common + "/packed-refs"):
    filesystem["allow_file"].append(common + "/packed-refs")
if kind == "ship" and mode == "no-mistakes":
    daemon_home = os.path.expanduser("~/.no-mistakes")
    if os.path.isdir(daemon_home):
        allow.append(daemon_home)
        filesystem["allow"] = sorted(set(allow))
    if sock and os.path.exists(sock):
        filesystem["unix_socket"] = [sock]
# A user profile named default shadows the built-in one, and its grants merge in with no removal.
profile = {
    "meta": {"name": "fm-pi-worker-" + task, "version": "1", "description": "Firstmate per-task pi worker profile"},
    "groups": {"include": ["deny_credentials", "deny_keychains_macos", "deny_keychains_linux", "deny_browser_data_macos", "deny_browser_data_linux", "deny_macos_private", "deny_shell_history", "deny_shell_configs", "system_read_macos", "system_read_linux_core", "system_write_macos", "system_write_linux", "user_tools", "homebrew_macos", "homebrew_linux", "dangerous_commands", "dangerous_commands_macos", "dangerous_commands_linux", "node_runtime", {"name": "user_caches_macos", "when": "macos"}, "nix_runtime", "git_config", "unlink_protection"], "exclude": ["system_write_macos"]},
    "security": {"signal_mode": "isolated", "capability_elevation": False},
    "filesystem": filesystem,
    "network": {
        "block": False,
        "allow_domain": ["github.com", "api.github.com", "registry.npmjs.org"] + (["api.anthropic.com"] if claude else []),
        "credentials": ["claude_bridge"] if claude else ["opencode_go"],
        "open_port": [],
        "listen_port": [],
        "custom_credentials": {"claude_bridge": {"upstream": "https://api.anthropic.com", "credential_key": "cmd://claude_bridge", "inject_header": "Authorization", "credential_format": "Bearer {}", "env_var": "ANTHROPIC_AUTH_TOKEN"}} if claude else {"opencode_go": {"upstream": "https://opencode.ai/zen/go/v1", "credential_key": "cmd://opencode_go", "inject_header": "Authorization", "credential_format": "Bearer {}", "env_var": "OPENCODE_GO_KEY"}},
    },
    "credential_capture": {"claude_bridge": {"command": ["/bin/sh", os.environ["FM_SANDBOX_CAPTURE"], "claude-bridge"], "timeout_secs": 15, "cache_ttl_secs": 900}} if claude else {"opencode_go": {"command": ["/bin/sh", os.environ["FM_SANDBOX_CAPTURE"], "opencode-go"], "timeout_secs": 15, "cache_ttl_secs": 900}},
    "workdir": {"access": "readwrite"},
}
with open(state + "/" + task + ".nono.json", "w") as handle:
    json.dump(profile, handle, indent=2)
    handle.write("\n")
if not claude:
    with open(task_tmp + "/pi-agent/models.json", "w") as handle:
        json.dump({"providers": {"opencode-go": {"apiKey": "$OPENCODE_GO_KEY"}}}, handle, indent=2)
        handle.write("\n")
else:
    bridge_pin = os.environ.get("FM_SANDBOX_BRIDGE_PIN", "git:github.com/avi2d/pi-claude-bridge@v0.9.3+avi2d.1")
    with open(task_tmp + "/pi-agent/settings.json", "w") as handle:
        json.dump({"packages": [bridge_pin]}, handle, indent=2)
        handle.write("\n")
EOF
  render_status=$?
  [ "$render_status" -eq 0 ] || { echo "error: sandbox profile render failed for $id" >&2; return 1; }
  FM_AGENT_SANDBOX_PI_BIN=$pi_bin FM_AGENT_SANDBOX_CAPTURE_LOG=$capture_log nono profile validate "$profile" >/dev/null 2>&1 || {
    echo "error: sandbox profile $profile failed nono validation" >&2
    return 1
  }
  printf 'profile=%s\npi_dir=%s\n' "$profile" "$pi_dir"
}

fm_sandbox_claude_token_check() {
  local token
  token=$(fm_sandbox_claude_token_path "$1")
  [ -f "$token" ] || {
    echo "error: no Claude setup token at $token; run claude setup-token and store its output there with chmod 600" >&2
    return 1
  }
  [ -s "$token" ] || { echo "error: Claude setup token at $token is empty" >&2; return 1; }
  case "$(uname -s)" in
  Darwin) perms=$(stat -f '%Lp' "$token") ;;
  *) perms=$(stat -c '%a' "$token") ;;
  esac
  case "$perms" in
  600 | 400) ;;
  *) echo "error: Claude setup token at $token must be readable only by its owner (chmod 600)" >&2; return 1 ;;
  esac
}

fm_sandbox_help() {
  printf '%s\n' "Usage: fm-agent-sandbox.sh enabled <config-dir> | pin <config-dir> | check <config-dir>"
  printf '%s\n' "       fm-agent-sandbox.sh model-route <model> | claude-token-path <config-dir>"
  printf '%s\n' "       fm-agent-sandbox.sh render <state-real> <id> <worktree> <task-tmp> <data-id-dir> <hooks-dir> <fm-root> <kind> <mode>"
  printf '%s\n' "       fm-agent-sandbox.sh claude-token-check <config-dir>"
}

case "${1:-}" in
"" | -h | --help) fm_sandbox_help; exit 0 ;;
enabled) fm_sandbox_enabled "$2" ;;
pin) fm_sandbox_pin "$2" ;;
check) fm_sandbox_check "$2" ;;
model-route) fm_sandbox_model_route "${2:-}" ;;
claude-token-path) fm_sandbox_claude_token_path "$2" ;;
claude-token-check) fm_sandbox_claude_token_check "$2" ;;
render) shift; fm_sandbox_render "$@" ;;
*) echo "error: unknown fm-agent-sandbox.sh command '$1'" >&2; exit 2 ;;
esac
