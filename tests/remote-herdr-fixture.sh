#!/usr/bin/env bash
# While <send-fail-flag> exists, every pane write fails.
install_remote_herdr_fixture() { # <remote-root> <state> <log> <send-fail> <socket>
  local remote_root=$1 state=$2 log=$3 send_fail=$4 socket=$5 script="$1/bin/herdr"
  mkdir -p "$remote_root/bin"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
STATE='$state'
LOG='$log'
SEND_FAIL='$send_fail'
SOCKET='$socket'
SH
  cat >> "$script" <<'SH'
printf '%s\n' "$*" >> "$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
ws=""; label=""; cwd=""; pane=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane=${args[$((i+1))]:-} ;;
  esac
done
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true,"protocol":16,"compatible":true}}\n' ;;
  "server "*|"server") : ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg cwd "$cwd" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, cwd:$cwd}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg cwd "$cwd" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, cwd:$cwd}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}' ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane"
    else
      jq_state -c --arg p "$pane" '{result:{pane:({pane_id:$p} + ([.tabs[]|select(.pane_id==$p)|.cwd // empty|{foreground_cwd:.}][0] // {}))}}'
    fi
    ;;
  "pane close")
    jq_state --arg p "${3:-}" \
      '.tabs |= [.[]|select(.pane_id != $p)]
       | .typed |= with_entries(select(.key != $p))
       | .working |= with_entries(select(.key != $p))' | save ;;
  "pane send-text")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" '.typed[$p] = true' | save ;;
  "pane send-keys")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" '.typed[$p] = true | .working[$p] = true' | save ;;
  "pane read") printf '\n' ;;
  "pane process-info")
    if [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}\n' \
        "$pane" "$$" "$$" "$$"
    else
      shell=$(cat "$STATE.shell-pid")
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"],"cmdline":"-zsh"}]}}}\n' \
        "$pane" "$shell" "$shell" "$shell"
    fi
    ;;
  "agent get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '.working[$p] // false')" = true ]; then
      jq_state --arg p "$pane" '.working |= with_entries(select(.key != $p))' | save
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found","message":"%s"}}\n' "$pane"
    fi
    ;;
  "session list"*)
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"},{"name":"fm-remote","running":true,"socket_path":"%s"}]}\n' "$SOCKET" "$SOCKET" ;;
esac
exit 0
SH
  chmod +x "$script"
  reset_remote_herdr_fixture "$state"
  # A bare shell reads agent-free only as a live pid with no harness under it.
  (
    i=0
    while [ -e "$state" ] && [ "$i" -lt 3600 ]; do
      sleep 1
      i=$((i + 1))
    done
  ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$state.shell-pid"
}

# reset_remote_herdr_fixture <state>: return the fake host to "no workspaces,
# tabs, or panes", which is what a test means by "the previous endpoint is gone".
reset_remote_herdr_fixture() { # <state>
  printf '{"next":1,"workspaces":[],"tabs":[],"typed":{},"working":{}}\n' > "$1"
}
