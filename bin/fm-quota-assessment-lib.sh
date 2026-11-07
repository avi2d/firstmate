# shellcheck shell=bash
fm_quota_assessment_jq() {
  cat <<'JQ'
  def quota_rows($row): ($row | .quotaSemantics.effectiveAvailability // []);
  def quota_bare_model($model): ($model | split("/") | last);
  def quota_applicable_rows($row; $model):
    (quota_bare_model($model)) as $bare |
    [quota_rows($row)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def quota_floor_state($floor; $row):
    if $floor == null then "none"
    elif $row == null or (["known", "partial"] | index($row.quotaSemantics.status)) == null then "unknown"
    else [quota_rows($row)[] | select(.scope == $floor.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $floor.min_percent) then "below"
        else "ok"
        end
    end;
  # One day is the longest a single task holds its worker from spawn to a
  # ready PR, so a reset inside it reaches the task before a reserve kept for
  # later work in that window could serve anyone; a weekly or monthly window
  # keeps its floor for all but its last day.
  def quota_floor_reset_horizon_seconds: 86400;
  def quota_reset_epoch:
    if type == "number" then (if . > 1000000000000 then . / 1000 else . end | floor)
    elif type == "string" then
      (try (capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$")
        | (.base + "Z" | fromdateiso8601)
          - (if .zone == "Z" then 0
             else (.zone[0:1] | if . == "-" then -1 else 1 end)
               * ((.zone[1:3] | tonumber) * 3600 + (.zone[4:6] | tonumber) * 60) end))
       catch null)
    else null end;
  # The reset that lifts a below-floor scope back to its floor, or null when
  # any window holding it down has no known reset inside the horizon.
  def quota_floor_reset($limit; $row):
    [quota_rows($row)[] | select(.scope == $limit.scope)] as $matches |
    (now | floor) as $now |
    [$matches[] | select(.effectivePercentRemaining < $limit.min_percent) |
      ((.boundedBy // .limitingWindowIds // [(.runway.limitingWindowId // empty)]) as $ids |
       [$row.windows[]? | select(.id as $id | $ids | index($id))] as $windows |
       [$windows[] | select((.percentRemaining | type) != "number" or .percentRemaining < $limit.min_percent)] as $holding |
       if .effectivePercentRemaining <= 0 or ($windows | length) < ($ids | length) or ($holding | length) == 0 then null
       else [$holding[] | {id, at: (.resetsAt | quota_reset_epoch)}] end)] as $held |
    if ($held | length) == 0 or any($held[]; . == null) or any($held[][]; .at == null or .at <= $now or .at > $now + quota_floor_reset_horizon_seconds) then null
    else ([$held[][]] | max_by(.at)) as $last |
      {resetsAt: ($last.at | todateiso8601), windows: ([$held[][].id] | unique)}
    end;
  def quota_profile_floor_state($floor; $row):
    quota_floor_state($floor; $row) as $state |
    if $state == "below" and quota_floor_reset($floor; $row) != null then "skipped" else $state end;
  def quota_runway_exhausted_rows($rows):
    [$rows[] | select((.runway.status // "") == "exhausted_now")];
JQ
}
