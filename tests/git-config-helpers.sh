#!/usr/bin/env bash
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
_fm_strip_env_hooks_path() {
  local i=0 kept=0 key value
  while true; do
    eval "key=\${GIT_CONFIG_KEY_$i-<unset>} value=\${GIT_CONFIG_VALUE_$i-<unset>}"
    [ "$key" = '<unset>' ] && [ "$value" = '<unset>' ] && break
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    case $key in
      [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh] | '<unset>') ;;
      *)
        if [ "$value" != '<unset>' ]; then
          export "GIT_CONFIG_KEY_$kept=$key" "GIT_CONFIG_VALUE_$kept=$value"
          kept=$((kept + 1))
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$kept" -eq 0 ]; then
    unset GIT_CONFIG_COUNT
  else
    export GIT_CONFIG_COUNT=$kept
  fi
}
_fm_strip_env_hooks_path
unset -f _fm_strip_env_hooks_path
