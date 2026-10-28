# shellcheck shell=bash
# The token reaches bws through BWS_ACCESS_TOKEN, because argv is visible to other local users.

fm_bws_token() {
  local token=''
  if command -v security >/dev/null 2>&1; then
    token=$(security find-generic-password -s bws-access-token -w 2>/dev/null) || token=''
  fi
  if [ -z "$token" ] && [ -s "$HOME/.config/bws/token" ]; then
    token=$(tr -d '\r\n' < "$HOME/.config/bws/token")
  fi
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

fm_bws_secret_value() {
  local id_file=$1 id token value
  id=$(tr -d '[:space:]' < "$id_file" 2>/dev/null) || id=''
  [ -n "$id" ] || { printf '%s\n' "bws: no secret id in $id_file" >&2; return 1; }
  command -v bws >/dev/null 2>&1 || { printf '%s\n' 'bws: the bws CLI is not installed' >&2; return 1; }
  token=$(fm_bws_token) || { printf '%s\n' 'bws: no access token (keychain item bws-access-token or ~/.config/bws/token)' >&2; return 1; }
  value=$(BWS_ACCESS_TOKEN="$token" bws secret get "$id" -o json 2>/dev/null | jq -r '.value // empty') || value=''
  [ -n "$value" ] || { printf '%s\n' "bws: could not read secret $id with the access token" >&2; return 1; }
  printf '%s' "$value"
}
