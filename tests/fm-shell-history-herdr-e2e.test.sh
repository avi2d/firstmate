#!/usr/bin/env bash
# Live-Herdr proof that guarded pane-shell lines execute yet never reach the
# shell's history file, while an unguarded control line does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_SHELL_HISTORY_HERDR_E2E herdr jq zsh bash

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-shell-history-herdr-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$PROJECT"
printf '# Isolated shell-history lab\n' > "$PROJECT/AGENTS.md"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-shell-history)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

backend() { # <pane> <line|literal|key> <payload...>
  # Mirror spawn's exact composition: shell lines pass raw into
  # send_text_line (the backend guards), while spawn_send_literal guards the
  # sourcing text itself before the raw send_literal transport.
  local pane=$1 op=$2
  shift 2
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/fm-shell-line-lib.sh"
    . "$1/bin/backends/herdr.sh"
    op=$2 tgt=$3
    shift 3
    case "$op" in
      line) fm_backend_herdr_send_text_line "$tgt" "$1" ;;
      literal) fm_backend_herdr_send_literal "$tgt" "$(fm_shell_history_prefix "$1")" ;;
      key) fm_backend_herdr_send_key "$tgt" "$1" ;;
    esac
  ' _ "$ROOT" "$op" "$HERDR_LAB_SESSION:$pane" "$@"
}

pane_capture() { # <pane>
  lab pane read --source recent --lines 200 "$1" 2>/dev/null
}

wait_for_capture() { # <pane> <token>
  local pane=$1 token=$2 i out
  for i in $(seq 1 60); do
    out=$(pane_capture "$pane") || true
    case "$out" in *"$token"*) return 0 ;; esac
    sleep 0.5
  done
  return 1
}

prove_shell() { # <zsh|bash>
  local shell=$1 case_dir hist stage pane tab target launch capture
  local ready_token="HISTPROBE_READY_$shell" control="HISTPROBE_CONTROL_$shell"
  local export_token="HISTPROBE_EXPORT_$shell" sourced="HISTPROBE_SOURCED_$shell"
  local panerun="HISTPROBE_PANERUN_$shell" stage_base="hist-stage-$shell.sh"
  case_dir="$TMP_ROOT/$shell"
  hist="$case_dir/hist"
  stage="$case_dir/$stage_base"
  mkdir -p "$case_dir"
  printf 'echo %s\n' "$sourced" > "$stage"
  case "$shell" in
    zsh)
      mkdir -p "$case_dir/zshdot"
      {
        printf 'HISTFILE="%s"\n' "$hist"
        printf 'HISTSIZE=50\nSAVEHIST=50\nsetopt HIST_IGNORE_SPACE\n'
        printf 'print -r -- "%s"\n' "$ready_token"
      } > "$case_dir/zshdot/.zshrc"
      launch="env ZDOTDIR=$case_dir/zshdot HISTFILE=$hist zsh"
      ;;
    bash)
      {
        printf 'HISTFILE="%s"\n' "$hist"
        printf 'HISTCONTROL=ignorespace\nHISTSIZE=50\n'
        printf 'echo "%s"\n' "$ready_token"
      } > "$case_dir/bashrc"
      launch="env HISTFILE=$hist HISTCONTROL=ignorespace bash --rcfile $case_dir/bashrc -i"
      ;;
  esac
  tab=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label "hist-$shell" --no-focus) \
    || fail "$shell: could not create the lab tab"
  pane=$(printf '%s' "$tab" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
    || fail "$shell: could not read the pane id"
  target="$pane"
  lab pane run "$pane" "$launch" >/dev/null || fail "$shell: could not start the inner shell"
  wait_for_capture "$pane" "$ready_token" \
    || fail "$shell: startup marker never printed, so HISTFILE routing is unproven"
  backend "$pane" line "echo $panerun" \
    || fail "$shell: guarded pane-run line refused"
  backend "$pane" literal "export $export_token=exported-value" \
    || fail "$shell: guarded export literal refused"
  backend "$pane" key Enter \
    || fail "$shell: Enter after the guarded export refused"
  sleep 1
  backend "$pane" literal ". '$stage'" \
    || fail "$shell: guarded sourcing literal refused"
  backend "$pane" key Enter \
    || fail "$shell: Enter after the guarded sourcing line refused"
  sleep 1
  capture=$(pane_capture "$pane")
  case "$capture" in
    *"$panerun"*) pass "$shell: guarded pane-run line executed" ;;
    *) fail "$shell: guarded pane-run line left no output (capture: ${capture: -400})" ;;
  esac
  case "$capture" in
    *"$sourced"*) pass "$shell: guarded sourcing line executed" ;;
    *) fail "$shell: guarded sourcing line never ran (capture: ${capture: -400})" ;;
  esac
  lab pane send-text "$pane" "export $control=control-value" >/dev/null \
    || fail "$shell: could not type the unguarded control line"
  lab pane send-keys "$pane" enter >/dev/null \
    || fail "$shell: could not submit the unguarded control line"
  sleep 1
  lab pane send-text "$pane" ' exit' >/dev/null \
    || fail "$shell: could not type the guarded exit line"
  lab pane send-keys "$pane" enter >/dev/null \
    || fail "$shell: could not submit the guarded exit line"
  local i
  for i in $(seq 1 60); do
    [ -f "$hist" ] && grep -qF "$control" "$hist" 2>/dev/null && break
    sleep 0.5
  done
  grep -qF "$control" "$hist" 2>/dev/null \
    || fail "$shell: control line missing from throwaway history (shell may not record at all)"
  pass "$shell: unguarded control line reached the throwaway history"
  if grep -qF "$export_token" "$hist"; then
    fail "$shell: guarded export line leaked into the throwaway history"
  fi
  pass "$shell: guarded export line absent from the throwaway history"
  if grep -qF "$stage_base" "$hist"; then
    fail "$shell: guarded sourcing line leaked into the throwaway history"
  fi
  pass "$shell: guarded sourcing line absent from the throwaway history"
}

WS_CREATE=$(lab workspace create --cwd "$PROJECT" --label hist-proof --no-focus) \
  || fail 'could not create the lab workspace'
WS=$(printf '%s' "$WS_CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail 'could not read the workspace id'

prove_shell zsh
prove_shell bash
