# shellcheck shell=bash

fm_quota_spawn_profiles() {
  local path=$1 harness=$2 model=$3 effort=$4 account=$5
  jq -c --arg harness "$harness" --arg model "$model" --arg effort "$effort" --arg account "$account" '
    def profiles($value): if ($value | type) == "array" then $value elif ($value | type) == "object" then [$value] else [] end;
    ([((.rules // [])[] | profiles(.use))[], profiles(.default // null)[]] |
      map(select(.harness == $harness and
        ((has("model") | not) or .model == $model) and
        ((has("effort") | not) or .effort == $effort) and
        (.claude_account // "") == $account)))
  ' "$path"
}

fm_quota_spawn_assess() {
  local row=$1 model=$2 floor=$3
  jq -c --arg model "$model" --argjson floor "$floor" "$(fm_quota_assessment_jq)"'
    . as $row |
    (quota_applicable_rows($row; $model)) as $rows |
    (quota_runway_exhausted_rows($rows)) as $exhausted |
    (quota_floor_state($floor; $row)) as $floor_state |
    ([quota_rows($row)[] | select(.scope == $floor.scope)] | first) as $floor_row |
    (if ($exhausted | length) > 0 then
       {blocked: true, reason: "quota exhausted now at \($exhausted[0].scope)", scope: $exhausted[0].scope}
     elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
       ([$rows[] | select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)][0]) as $bad |
       {blocked: true, reason: "quota exhausted now at \($bad.scope)", scope: $bad.scope}
     elif $floor_state == "below" then
       {blocked: true, reason: "quota at \($floor.scope) below \($floor.min_percent)%", scope: $floor.scope, remaining: $floor_row.effectivePercentRemaining}
     else {blocked: false, floor_state: $floor_state} end) as $decision |
    ([quota_rows($row)[] | select(.scope == $decision.scope)] | first) as $blocking |
    (if ($blocking.runway.limitingWindowId // null) != null then [$blocking.runway.limitingWindowId] else ($blocking.limitingWindowIds // []) end) as $window_ids |
    ([$row.windows[]? | select(.id as $id | $window_ids | index($id)) | .resetsAt | select((type == "string" and length > 0) or type == "number")]) as $window_resets |
    (($window_resets | map(if type == "number" then ((. / (if . > 1000000000000 then 1000 else 1 end) | floor) | todateiso8601) else . end) | max) // $row.resetsAt // null) as $resets_at |
    $decision + {resetsAt: $resets_at, unmeasured: ($row == null or $floor_state == "unknown" or ($rows | length) == 0 or any($rows[]; .status != "known"))}
  ' <<< "$row"
}

fm_quota_spawn_gate_note() {
  printf '%s' "${FM_QUOTA_GATE_NOTE:-}"
}
fm_quota_spawn_gate() {
  local config=$1 harness=$2 model=$3 effort=$4 account=$5 override=$6
  local profiles count snapshot='' profile provider lane floor row assessment blocked=0 unmeasured=0 result reason reset account_name clauth_snapshot=''
  FM_QUOTA_GATE_NOTE=
  if [ ! -e "$config" ] && [ ! -L "$config" ]; then
    FM_QUOTA_GATE_NOTE='skipped:no dispatch profile file'
    printf '%s\n' 'quota gate skipped: config/crew-dispatch.json is absent' >&2
    return 0
  fi
  [ -f "$config" ] && [ -r "$config" ] || {
    echo "error: quota gate cannot read dispatch profiles at $config" >&2
    return 2
  }
  profiles=$(fm_quota_spawn_profiles "$config" "$harness" "$model" "$effort" "$account") || {
    echo "error: quota gate could not parse dispatch profiles at $config" >&2
    return 2
  }
  count=$(jq 'length' <<< "$profiles")
  if [ "$count" -eq 0 ]; then
    FM_QUOTA_GATE_NOTE='skipped:no matching dispatch profile'
    printf '%s\n' 'quota gate skipped: no dispatch profile matches the selected launch' >&2
    return 0
  fi
  local resolved_profiles='[]'
  while IFS= read -r profile; do
    if ! jq -e '
      ((has("provider") | not) or (.provider | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))) and
      ((has("floor") | not) or (.floor | type == "object" and (.scope | type == "string" and length > 0) and (.min_percent | type == "number" and . >= 0 and . <= 100)))
    ' <<< "$profile" >/dev/null; then
      echo 'error: a matching dispatch profile has a malformed provider or quota floor' >&2
      return 2
    fi
    provider=$(jq -r '.provider // empty' <<< "$profile")
    [ -n "$provider" ] || provider=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null || true)
    [ -n "$provider" ] || {
      echo 'error: a matching profile has no provider mapping' >&2
      return 2
    }
    resolved_profiles=$(jq -cn --argjson profiles "$resolved_profiles" --argjson profile "$profile" --arg provider "$provider" '$profiles + [($profile + {_quota_provider: $provider})]') || return 2
  done < <(jq -c '.[]' <<< "$profiles")
  profiles=$(jq -c --argjson all "$resolved_profiles" '$all | map(. as $profile | if $profile.floor then .floor.min_percent = ([$all[] | select(._quota_provider == $profile._quota_provider and .floor.scope == $profile.floor.scope) | .floor.min_percent] | max) else . end)' <<< "$resolved_profiles") || return 2
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    provider=$(jq -r '._quota_provider' <<< "$profile")
    lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)')
    floor=$(jq -c '.floor // null' <<< "$profile")
    account_name=$(jq -r '.claude_account // empty' <<< "$profile")
    if [ -n "$account_name" ]; then
      if [ -z "$clauth_snapshot" ]; then
        clauth_snapshot=$(fm_clauth_status 2>/dev/null) || {
          FM_QUOTA_GATE_NOTE='skipped:clauth reading unavailable'
          printf '%s\n' 'quota gate skipped: clauth could not provide an account reading' >&2
          return 0
        }
      fi
      row=$(jq -c --arg account "$account_name" "$FM_CLAUTH_ROW_JQ"'clauth_row(.; $account)' <<< "$clauth_snapshot")
      if jq -e 'has("unusable")' <<< "$row" >/dev/null; then
        FM_QUOTA_GATE_NOTE='skipped:clauth account reading unusable'
        printf 'quota gate skipped: clauth cannot verify account %s\n' "$account_name" >&2
        return 0
      fi
    else
      if [ -z "$snapshot" ]; then
        command -v quota-axi >/dev/null 2>&1 || {
          FM_QUOTA_GATE_NOTE='skipped:quota-axi unavailable'
          printf '%s\n' 'quota gate skipped: quota-axi is unavailable' >&2
          return 0
        }
        snapshot=$(fm_run_timed 5 quota-axi --json --no-credential-refresh 2>/dev/null </dev/null) || {
          FM_QUOTA_GATE_NOTE='skipped:quota reading unavailable'
          printf '%s\n' 'quota gate skipped: quota-axi could not provide a reading' >&2
          return 0
        }
        printf '%s\n' "$snapshot" | fm_quota_json_valid || {
          FM_QUOTA_GATE_NOTE='skipped:quota reading invalid'
          printf '%s\n' 'quota gate skipped: quota-axi returned an invalid reading' >&2
          return 0
        }
      fi
      row=$(jq -c --arg provider "$provider" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'quota_row(.; $provider; $lane)' <<< "$snapshot")
    fi
    assessment=$(fm_quota_spawn_assess "$row" "$model" "$floor") || {
      echo 'error: quota assessment rejected a matching profile or quota row' >&2
      return 2
    }
    [ "$(jq -r '.unmeasured' <<< "$assessment")" != true ] || unmeasured=1
    if [ "$(jq -r '.blocked' <<< "$assessment")" = true ]; then
      blocked=1
      reason=$(jq -r '.reason' <<< "$assessment")
      reset=$(jq -r '.resetsAt // "reset time unavailable"' <<< "$assessment")
      result="$reason; resets at $reset"
      break
    fi
  done < <(jq -c '.[]' <<< "$profiles")
  if [ "$blocked" = 1 ]; then
    if [ -n "$override" ]; then
      FM_QUOTA_GATE_NOTE="overridden:$override"
      printf 'quota gate override: %s (%s)\n' "$result" "$override" >&2
      return 0
    fi
    FM_QUOTA_GATE_NOTE="refused:$result"
    printf 'error: %s; provide --quota-override-reason with a concrete reason to proceed\n' "$result" >&2
    return 1
  fi
  if [ "$unmeasured" = 1 ]; then
    FM_QUOTA_GATE_NOTE='checked:unmeasured'
  else
    FM_QUOTA_GATE_NOTE='checked:available'
  fi
  return 0
}
