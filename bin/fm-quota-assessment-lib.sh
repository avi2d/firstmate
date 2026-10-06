# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034  # jq program text, read by the sourcing consumers
FM_QUOTA_ASSESSMENT_JQ=$(cat <<'JQ'
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
  def quota_runway_exhausted_rows($rows):
    [$rows[] | select((.runway.status // "") == "exhausted_now")];
JQ
)
