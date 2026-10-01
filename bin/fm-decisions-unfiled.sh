#!/usr/bin/env bash
# fm-decisions-unfiled.sh - list dated captain.md rulings no decisions record cites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CAPTAIN="${FM_DATA_OVERRIDE:-$FM_HOME/data}/captain.md"
DECISIONS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/decisions"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain) CAPTAIN=${2:-}; shift 2 ;;
    --decisions) DECISIONS=${2:-}; shift 2 ;;
    -h|--help)
      printf 'usage: fm-decisions-unfiled.sh [--captain <file>] [--decisions <dir>]\n'
      printf 'defaults: <home>/data/captain.md and <home>/projects/decisions.\n'
      printf 'A ruling is cited when a record carries its date and quotes its words byte for byte in either direction.\n'
      printf 'Records hold raw chat words the bullets paraphrase, so date alone would let one filed record hide same-date rulings.\n'
      printf 'A bullet with no quoted words falls back to date alone; a record without a words section cites nothing.\n'
      printf 'Reads only; prints one date-plus-opening-words line per uncited ruling, nothing when every ruling is cited.\n'
      exit 0
      ;;
    *) printf 'fm-decisions-unfiled: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "${CAPTAIN:-}" ] && [ -f "$CAPTAIN" ] && [ -s "$CAPTAIN" ] || exit 0
RECORDS_DIR="$DECISIONS/docs/adr"
[ -d "$RECORDS_DIR" ] || exit 0

shopt -s nullglob
DATE_FILES=""
QUOTE_LINES=""
for rec in "$RECORDS_DIR"/*.md; do
  [ -f "$rec" ] || continue
  grep -qi "captain's words" "$rec" || continue
  rec_date=$(sed -n 's/^Date:[[:space:]]*\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' "$rec" | head -n 1)
  [ -n "$rec_date" ] || continue
  DATE_FILES=$(printf '%s\n%s\t%s' "$DATE_FILES" "$rec_date" "$rec")
  while IFS= read -r quote || [ -n "$quote" ]; do
    [ -n "$quote" ] || continue
    QUOTE_LINES=$(printf '%s\n%s\t%s' "$QUOTE_LINES" "$rec_date" "$quote")
  done < <(sed -n 's/^>[[:space:]]*//p' "$rec")
done

first_words() {
  awk '{ s=""; for (i=1; i<=12 && i<=NF; i++) s=s (i>1 ? " " : "") $i; print s (NF>12 ? " ..." : "") }'
}

while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ ^-[[:space:]]+([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]):[[:space:]]*(.*)$ ]]; then
    bullet_date=${BASH_REMATCH[1]}
    bullet_text=${BASH_REMATCH[2]}
  else
    continue
  fi
  cited=0
  bullet_quotes=$(printf '%s\n' "$bullet_text" | grep -Eo '"[^"]+"' | tr -d '"' || true)
  if [ -n "$bullet_quotes" ]; then
    while IFS= read -r quoted || [ -n "$quoted" ]; do
      [ -n "$quoted" ] || continue
      while IFS= read -r dfline || [ -n "$dfline" ]; do
        [ -n "$dfline" ] || continue
        [ "${dfline%%	*}" = "$bullet_date" ] || continue
        if grep -qF -- "$quoted" "${dfline#*	}"; then cited=1; break 2; fi
      done <<< "$DATE_FILES"
    done <<< "$bullet_quotes"
    if [ "$cited" -eq 0 ]; then
      while IFS= read -r qline || [ -n "$qline" ]; do
        [ -n "$qline" ] || continue
        [ "${qline%%	*}" = "$bullet_date" ] || continue
        case "$bullet_text" in
          *"${qline#*	}"*) cited=1; break ;;
        esac
      done <<< "$QUOTE_LINES"
    fi
  else
    while IFS= read -r dfline || [ -n "$dfline" ]; do
      [ -n "$dfline" ] || continue
      if [ "${dfline%%	*}" = "$bullet_date" ]; then cited=1; break; fi
    done <<< "$DATE_FILES"
  fi
  if [ "$cited" -eq 0 ]; then
    printf '%s: %s\n' "$bullet_date" "$(printf '%s\n' "$bullet_text" | first_words)"
  fi
done < "$CAPTAIN"

exit 0
