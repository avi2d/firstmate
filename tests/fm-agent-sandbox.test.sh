#!/usr/bin/env bash
# fm-agent-sandbox opt-in gate, model routing, and per-task profile render.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sandbox)
SB="$ROOT/bin/fm-agent-sandbox.sh"

cfg_off="$TMP_ROOT/off"
mkdir -p "$cfg_off"
if "$SB" enabled "$cfg_off"; then fail "absent config enables nothing"; fi
pass "absent config leaves the sandbox off"

cfg_bad="$TMP_ROOT/bad"
mkdir -p "$cfg_bad"
printf '# only a comment\n' >"$cfg_bad/agent-sandbox"
if "$SB" pin "$cfg_bad" >/dev/null 2>&1; then fail "versionless config pins a version"; fi
pass "versionless config refuses to pin"

cfg="$TMP_ROOT/on"
mkdir -p "$cfg"
printf '0.80.0\n' >"$cfg/agent-sandbox"
"$SB" enabled "$cfg" || fail "present config enables the sandbox"
[ "$("$SB" pin "$cfg")" = "0.80.0" ] || fail "pin reads the file"
pass "present config enables the sandbox and pins the version"

[ "$("$SB" model-route "")" = unknown ] || fail "empty model route"
[ "$("$SB" model-route default)" = unknown ] || fail "default model route"
[ "$("$SB" model-route claude-bridge/abc)" = claude ] || fail "claude model route"
[ "$("$SB" model-route opencode-go/glm-5.3-flash)" = "proxy:opencode-go" ] || fail "opencode-go model route"
[ "$("$SB" model-route openai-codex/gpt-6-luna)" = "unsupported:openai-codex" ] || fail "other provider route"
pass "model routing separates proxy, claude, and unsupported providers"

fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\necho "nono 0.79.0"\n' >"$fakebin/nono"
chmod +x "$fakebin/nono"
if PATH="$fakebin:$PATH" "$SB" check "$cfg"; then fail "fake nono passes check"; fi
pass "version check refuses a wrong nono"

if command -v nono >/dev/null 2>&1; then
  "$SB" check "$cfg" || fail "real nono 0.80.0 passes check"
  pass "real nono passes the pinned check"
else
  pass "real nono absent so the pinned check is untested here"
fi

tok="$("$SB" claude-token-path "$cfg")"
[ "$tok" = "$cfg/agent-sandbox-claude-token" ] || fail "claude token path"
if "$SB" claude-token-check "$cfg" 2>/dev/null; then fail "absent claude token passes"; fi
pass "claude token check refuses an absent token"

state="$TMP_ROOT/home/state"
wt="$TMP_ROOT/home/wt"
data_id="$TMP_ROOT/home/data/t1"
tmp="$TMP_ROOT/home/tmp-t1"
mkdir -p "$state" "$wt" "$data_id" "$tmp"
(cd "$wt" && git init -q && git config user.email t@t && git config user.name t && printf x >f && git add f && git commit -qm init)
touch "$state/t1.pi-ext.ts" "$state/t1.status"
render_out=$("$SB" render "$state" t1 "$wt" "$tmp" "$data_id" "$TMP_ROOT/home/hooks" "$ROOT" scout "") || fail "render scout profile"
profile=$(printf '%s\n' "$render_out" | sed -n 's/^profile=//p')
[ -f "$profile" ] || fail "render prints the profile path"
export FM_TEST_WT="$wt"
python3 - "$profile" <<'EOF' || fail "rendered profile content"
import json, os, sys
wt_dir = os.environ["FM_TEST_WT"]
profile = json.load(open(sys.argv[1]))
assert profile["extends"] == "default"
includes = [g if isinstance(g, str) else g["name"] for g in profile["groups"]["include"]]
assert "system_write_macos" not in profile["groups"].get("exclude", []) or True
assert "system_write_macos" in profile["groups"]["exclude"], includes
assert "node_runtime" in includes
fs = profile["filesystem"]
joined = " ".join(fs["allow"] + fs["read"] + fs.get("allow_file", []) + fs.get("read_file", []) + fs.get("write_file", []))
assert ".pi/agent" not in joined.replace("pi-agent", ""), joined
assert "opencode.ai" in json.dumps(profile["network"])
assert "unix_socket" not in fs
wt_common = __import__("subprocess").check_output(["git", "-C", wt_dir, "rev-parse", "--git-common-dir"], text=True).strip()
if not wt_common.startswith("/"):
    wt_common = wt_dir + "/" + wt_common
assert wt_common in fs["read"], fs["read"]
assert wt_common not in fs["allow"]
EOF
pass "scout profile carries the hardened shape and no daemon socket"

render_ship=$("$SB" render "$state" t1 "$wt" "$tmp" "$data_id" "$TMP_ROOT/home/hooks" "$ROOT" ship no-mistakes) || fail "render ship profile"
profile_ship=$(printf '%s\n' "$render_ship" | sed -n 's/^profile=//p')
if [ -S "$HOME/.no-mistakes/socket" ]; then
  python3 - "$profile_ship" <<'EOF' || fail "ship profile socket grant"
import json, os, subprocess, sys
fs = json.load(open(sys.argv[1]))["filesystem"]
assert fs.get("unix_socket") == [os.path.expanduser("~/.no-mistakes/socket")]
assert os.path.expanduser("~/.no-mistakes") in fs["allow"]
wt_common = subprocess.check_output(["git", "-C", os.environ["FM_TEST_WT"], "rev-parse", "--git-common-dir"], text=True).strip()
if not wt_common.startswith("/"):
    wt_common = os.environ["FM_TEST_WT"] + "/" + wt_common
assert wt_common in fs["allow"], fs["allow"]
EOF
  pass "no-mistakes ship profile grants the daemon socket"
else
  pass "daemon socket absent so the ship socket grant is untested here"
fi

[ -f "$tmp/pi-agent/models.json" ] || fail "per-task pi models file"
pass "render writes the per-task pi directory"
