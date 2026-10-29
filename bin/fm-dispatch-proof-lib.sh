# shellcheck shell=bash
# A bare harness flag copies cleanly, so the launch needs proof the rules were read.

FM_DISPATCH_PROOF_NOTE=
_FM_DISPATCH_REASON=

fm_dispatch_proof_note() {
  printf '%s' "${FM_DISPATCH_PROOF_NOTE:-}"
}

_dispatch_proof_flag() {
  local line=$1 flag=$2 hit
  hit=$(printf '%s\n' "$line" | grep -o -- "$flag [^ ]*" | head -n 1) || return 1
  hit=${hit#"$flag "}
  hit=$(printf '%s' "$hit" | tr -d \'\") || return 1
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

_dispatch_proof_axis_matches() {
  local line=$1 flag=$2 launch=$3 want
  case "$launch" in
  "" | default) launch="" ;;
  esac
  want=$(_dispatch_proof_flag "$line" "$flag") || want=""
  [ "$want" = "$launch" ]
}

_dispatch_proof_profile_matches() {
  local line=$1 harness=$2 model=$3 effort=$4 account=$5 want
  want=$(_dispatch_proof_flag "$line" "--harness") || return 1
  [ "$want" = "$harness" ] || return 1
  _dispatch_proof_axis_matches "$line" "--model" "$model" || return 1
  _dispatch_proof_axis_matches "$line" "--effort" "$effort" || return 1
  _dispatch_proof_axis_matches "$line" "--claude-account" "$account" || return 1
  return 0
}

_dispatch_proof_launch_summary() {
  local harness=$1 model=$2 effort=$3 account=$4 summary
  summary="--harness $harness"
  case "$model" in "" | default) ;; *) summary="$summary --model $model" ;; esac
  case "$effort" in "" | default) ;; *) summary="$summary --effort $effort" ;; esac
  [ -z "$account" ] || summary="$summary --claude-account $account"
  printf '%s' "$summary"
}

_dispatch_proof_resolve_ok() {
  local file=$1 harness=$2 model=$3 effort=$4 account=$5 profile
  grep -Eq '^[[:space:]]*status:[[:space:]]*clear([[:space:]]|$)' "$file" || {
    _FM_DISPATCH_REASON="resolver output has no clear status"
    return 1
  }
  profile=$(grep -E '^[[:space:]]*profile:' "$file" | head -n 1) || profile=""
  [ -n "$profile" ] || {
    _FM_DISPATCH_REASON="resolver output has a clear status and no profile line"
    return 1
  }
  _dispatch_proof_profile_matches "$profile" "$harness" "$model" "$effort" "$account" || {
    _FM_DISPATCH_REASON="resolver profile does not match the launch"
    return 1
  }
  return 0
}

_dispatch_proof_record_ok() {
  local file=$1 harness=$2 model=$3 effort=$4 account=$5 chosen rest kind
  grep -Eq '^rule:[[:space:]]*[^[:space:]]' "$file" || {
    printf '%s' "selection record names no matched rule"
    return 1
  }
  [ "$(grep -Ec '^candidate:' "$file")" -gt 0 ] || {
    printf '%s' "selection record names no candidate"
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
    *"->"*)
      rest=${line#*"->"}
      [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ] || {
        printf '%s' "selection record leaves a candidate with no verdict"
        return 1
      }
      ;;
    *)
      printf '%s' "selection record leaves a candidate with no verdict"
      return 1
      ;;
    esac
  done < <(grep -E '^candidate:' "$file")
  chosen=$(grep -E '^chosen:' "$file" | head -n 1) || chosen=""
  [ -n "$chosen" ] || {
    printf '%s' "selection record names no chosen profile"
    return 1
  }
  _dispatch_proof_profile_matches "$chosen" "$harness" "$model" "$effort" "$account" || {
    printf '%s' "selection record chosen profile does not match the launch"
    return 1
  }
  if grep -Eq '^override:' "$file"; then
    grep -Eq '^override:[[:space:]]*[^[:space:]]' "$file" || {
      printf '%s' "override names no stated reason"
      return 1
    }
    kind="record:override"
  else
    kind="record:selection"
  fi
  printf '%s' "$kind"
  return 0
}

fm_dispatch_proof_gate() {
  local data=$1 id=$2 harness=$3 model=$4 effort=$5 account=$6
  local resolve_file="$data/$id/dispatch-resolve.out"
  local record_file="$data/$id/dispatch-selection.md"
  local reason_resolve="" reason_record="" kind="" seen_resolve=0 seen_record=0
  FM_DISPATCH_PROOF_NOTE=
  if [ -f "$resolve_file" ] && [ -r "$resolve_file" ]; then
    seen_resolve=1
    if _dispatch_proof_resolve_ok "$resolve_file" "$harness" "$model" "$effort" "$account"; then
      FM_DISPATCH_PROOF_NOTE="resolve:clear"
      printf '%s\n' "dispatch proof accepted: resolver clear for $id" >&2
      return 0
    fi
    reason_resolve=$_FM_DISPATCH_REASON
  fi
  if [ -f "$record_file" ] && [ -r "$record_file" ]; then
    seen_record=1
    kind=$(_dispatch_proof_record_ok "$record_file" "$harness" "$model" "$effort" "$account") || {
      reason_record=$kind
      kind=""
    }
    if [ -n "$kind" ]; then
      FM_DISPATCH_PROOF_NOTE="$kind"
      printf '%s\n' "dispatch proof accepted: selection record for $id" >&2
      return 0
    fi
  fi
  if [ "$seen_resolve" -eq 0 ] && [ "$seen_record" -eq 0 ]; then
    printf 'error: config/crew-dispatch.json is active and data/%s holds no dispatch proof - save the resolver output as data/%s/dispatch-resolve.out or write the selection record as data/%s/dispatch-selection.md and spawn again\n' "$id" "$id" "$id" >&2
    return 1
  fi
  [ "$seen_resolve" -eq 0 ] || printf 'error: dispatch proof refused: %s\n' "$reason_resolve" >&2
  [ "$seen_record" -eq 0 ] || printf 'error: dispatch proof refused: %s\n' "$reason_record" >&2
  printf 'error: the chosen profile must equal the launch: %s\n' "$(_dispatch_proof_launch_summary "$harness" "$model" "$effort" "$account")" >&2
  return 1
}
