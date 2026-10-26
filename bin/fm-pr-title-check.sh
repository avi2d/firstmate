#!/usr/bin/env bash
# Exits 0 when the title passes; otherwise exits 1 and lists each failed rule.
# The kit is a separate checkout, so its rule is copied here, not run.
set -u

if [ "$#" -ne 1 ]; then
  echo "usage: fm-pr-title-check.sh <title>" >&2
  exit 2
fi
title=$1

TYPES='build chore ci docs feat fix perf refactor revert style test theme renamer shell pi home audit comments unslop'

# Forms commitlint ignores by default; they carry no type.
IGNORED=(
  '^Merge pull request'
  '^Merge .* into '
  '^Merge branch '
  '^Merge tag '
  '^[Rr]evert '
  '^[Rr]eapply '
  '^(amend|fixup|squash)!'
  '^Merged .*(in|into) '
  '^Merged PR .*: '
  '^Merge remote-tracking branch'
  '^Automatic merge'
  '^Auto-merged .* into '
)
for pattern in "${IGNORED[@]}"; do
  if [[ $title =~ $pattern ]]; then
    exit 0
  fi
done

FORM='^([A-Za-z]+)(\([^)]*\))?!?: +(.*[^[:space:]].*)$'
reasons=()
if [[ $title =~ $FORM ]]; then
  type=${BASH_REMATCH[1]}
  subject=${BASH_REMATCH[3]}
  case " $TYPES " in
    *" $type "*) ;;
    *) reasons+=("type \"$type\" is not a conventional type; use one of: $TYPES") ;;
  esac
  # Capital letters come from LC_CTYPE, so a UTF-8 locale is needed to catch non-ASCII capitals.
  if [[ $subject =~ ^[[:upper:]] ]]; then
    reasons+=("subject \"$subject\" starts with a capital letter; start it lowercase")
  fi
else
  reasons+=("title does not read as type(scope): subject, for example fix(parser): handle an empty file")
fi
if [ "${#title}" -ge 90 ]; then
  reasons+=("title is ${#title} characters; it must be under 90")
fi

if [ "${#reasons[@]}" -eq 0 ]; then
  exit 0
fi
printf '  - %s\n' "${reasons[@]}"
exit 1
