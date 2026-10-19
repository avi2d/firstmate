#!/usr/bin/env bash
# fm-project-tiers-lib.sh - this home's optional dispatch tier for each project,
# and the ready-listing order it gives (docs/configuration.md "Project tiers").

fm_project_tiers_refuse() {  # <problem>
  FM_PROJECT_TIERS=
  printf 'project tiers not applied: %s\n' "$1" >&2
}

# Sets FM_PROJECT_TIERS_FILE, and FM_PROJECT_TIERS to one <name>\034<tier>
# entry per line, empty when the file is absent.
# Returns 1 and names the problem on stderr when the file cannot be read or a
# line is malformed, because skipping a line would silently demote that project.
fm_project_tiers_read() {  # <config-dir>
  local line lineno=0 name tier seen=$'\n'
  FM_PROJECT_TIERS_FILE="$1/project-tiers"
  FM_PROJECT_TIERS=
  if [ ! -e "$FM_PROJECT_TIERS_FILE" ] && [ ! -L "$FM_PROJECT_TIERS_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_TIERS_FILE" ] || [ ! -r "$FM_PROJECT_TIERS_FILE" ]; then
    fm_project_tiers_refuse "$FM_PROJECT_TIERS_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    tier=${line##*[[:space:]]}
    name=${line%"$tier"}
    name=${name%"${name##*[![:space:]]}"}
    case "$tier" in
      P[0-3]) ;;
      *)
        fm_project_tiers_refuse "$FM_PROJECT_TIERS_FILE line $lineno is not '<project-name> P0|P1|P2|P3'"
        return 1
        ;;
    esac
    if [ -z "$name" ]; then
      fm_project_tiers_refuse "$FM_PROJECT_TIERS_FILE line $lineno names no project before $tier"
      return 1
    fi
    case "$seen" in
      *$'\n'"$name"$'\n'*)
        fm_project_tiers_refuse "$FM_PROJECT_TIERS_FILE line $lineno names $name a second time"
        return 1
        ;;
    esac
    seen="$seen$name"$'\n'
    FM_PROJECT_TIERS="$FM_PROJECT_TIERS$name"$'\034'"${tier#P}"$'\n'
  done < "$FM_PROJECT_TIERS_FILE"
  return 0
}

# Filters tasks-axi ready output: rows under its ready[N]{...} header move
# P0 first through P3, then untiered, keeping tasks-axi's order within a tier.
# Every other line passes through in place.
# Precondition: fm_project_tiers_read succeeded in this shell.
fm_project_tiers_order_ready() {
  FM_PROJECT_TIERS_AWK=$FM_PROJECT_TIERS awk '
    BEGIN {
      untiered = 4
      n = split(ENVIRON["FM_PROJECT_TIERS_AWK"], entries, "\n")
      for (i = 1; i <= n; i++) {
        if (split(entries[i], kv, "\034") == 2) tier_of[kv[1]] = kv[2]
      }
    }
    function field(row, want,    i, c, len, k, value, quoted) {
      k = 1; value = ""; quoted = 0
      len = length(row)
      for (i = 1; i <= len; i++) {
        c = substr(row, i, 1)
        if (quoted) {
          if (c == "\\" && i < len) { i++; value = value substr(row, i, 1); continue }
          if (c == "\"") { quoted = 0; continue }
          value = value c
          continue
        }
        if (c == "\"") { quoted = 1; continue }
        if (c == ",") {
          if (k == want) return value
          k++; value = ""
          continue
        }
        value = value c
      }
      return k == want ? value : ""
    }
    function flush(    t, i) {
      for (t = 0; t <= untiered; t++)
        for (i = 1; i <= count[t]; i++) print bucket[t, i]
      for (t = 0; t <= untiered; t++) count[t] = 0
      if (!repo_col) print "(project tiers not applied: this ready listing has no repo column)"
      rows = 0
    }
    /^ready\[[0-9]+\]\{.*\}:[[:space:]]*$/ {
      if (rows) flush()
      print
      header = $0
      sub(/^ready\[[0-9]+\]\{/, "", header)
      sub(/\}:[[:space:]]*$/, "", header)
      repo_col = 0
      ncols = split(header, cols, ",")
      for (i = 1; i <= ncols; i++) if (cols[i] == "repo") repo_col = i
      rows = 1
      next
    }
    rows && /^[[:space:]]/ {
      row = $0
      sub(/^[[:space:]]+/, "", row)
      repo = repo_col ? field(row, repo_col) : ""
      t = (repo in tier_of) ? tier_of[repo] : untiered
      bucket[t, ++count[t]] = $0
      next
    }
    rows { flush() }
    { print }
    END { if (rows) flush() }
  '
}
