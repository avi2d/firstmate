# shellcheck shell=bash
# Reads clauth, the Claude account manager, and never writes it: running
# `clauth switch` would move the machine's login under every live session.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_CLAUTH_STATUS_SECONDS=${FM_CLAUTH_STATUS_SECONDS:-15}

# Prints one snapshot carrying a profile list, or one reason on stderr and returns 1.
fm_clauth_status() {
  local out
  command -v clauth >/dev/null 2>&1 || {
    echo "clauth is not installed" >&2
    return 1
  }
  out=$(fm_run_timed "$FM_CLAUTH_STATUS_SECONDS" clauth status --json 2>/dev/null </dev/null) || {
    echo "clauth status --json failed" >&2
    return 1
  }
  printf '%s\n' "$out" | jq -e '
    type == "object" and (.profiles | type) == "array"
    and all(.profiles[]; type == "object" and (.name | type) == "string")' >/dev/null 2>&1 || {
    echo "clauth status --json returned no profile list" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# clauth_row($status; $account) is a quota-axi-shaped provider row, or
# {unusable: <reason>} whenever the reading cannot vouch for the account.
# clauth projects no runway or spendPriority, so a row carries no selection.
# shellcheck disable=SC2016,SC2034  # jq program text, read by the sourcing consumers
FM_CLAUTH_ROW_JQ='
  def clauth_row($status; $account):
    ([$status.profiles[]? | select(.name == $account)] | first) as $p |
    def util($label): ([$p.windows[]? | select(.label == $label) | .utilization_pct] | first);
    def remaining($used): ([[100 - $used, 0] | max, 100] | min);
    def row($scope; $pct):
      {scope: $scope, status: "known", effectivePercentRemaining: $pct,
       runway: {status: (if $pct <= 0 then "exhausted_now" else "unknown" end)}};
    if $p == null then {unusable: "clauth has no profile \($account)"}
    elif $p.auth_status != "ok" then {unusable: "clauth reports auth \($p.auth_status // "unknown") for account \($account)"}
    elif $p.fetch_status == "Failed" then {unusable: "clauth could not read usage for account \($account)"}
    elif $p.stale != false then {unusable: "clauth reading for account \($account) is stale (fetched \($p.fetched_at // "never"))"}
    elif (util("5h") | type) != "number" or (util("7d") | type) != "number" then
      {unusable: "clauth reading for account \($account) lacks its 5h and 7d windows"}
    else
      (remaining([util("5h"), util("7d")] | max)) as $all |
      {provider: "claude", accountKey: $account, clauth: true,
       quotaSemantics: {status: "known", effectiveAvailability:
         ([row("all_models"; $all)]
          + [$p.windows[] | select((.label | startswith("7d ")) and (.utilization_pct | type) == "number")
             | row("model:" + (.label | ltrimstr("7d ")); ([$all, remaining(.utilization_pct)] | min))])}}
    end;
'
