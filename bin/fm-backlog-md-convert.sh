#!/usr/bin/env bash
set -eu

usage() {
  printf '%s\n' \
    'Usage: fm-backlog-md-convert.sh [--dry-run] <backlog.md> [done-archive.md]' \
    '       fm-backlog-md-convert.sh --apply <board-data-dir> <backlog.md> [done-archive.md]' \
    '' \
    'Use copies of the source files.' \
    'Dry run prints counts without opening a destination or writing files.' \
    'Apply imports into an initialized, empty Backlog.md lab board.'
}

destination=
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --apply)
    if [ "$#" -lt 3 ] || [ -z "$2" ]; then usage >&2; exit 2; fi
    destination=$2
    shift 2
    ;;
  --dry-run) shift ;;
  --) shift ;;
  -*) usage >&2; exit 2 ;;
esac
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage >&2; exit 2; fi

runner="$(dirname "${BASH_SOURCE[0]}")/fm-backlog-md"
if [ -n "$destination" ]; then
  exec python3 "$runner/locked.py" "$destination" "$runner/convert.cjs" "$@"
fi
exec node "$runner/convert.cjs" '' "$@"
