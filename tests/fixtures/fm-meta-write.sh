#!/usr/bin/env bash
set -eu
. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
meta=$1
lock=$(fm_meta_lock_path "$meta")
fm_lock_acquire_wait "$lock"
trap 'fm_lock_release "$lock"' EXIT
tmp=$(mktemp "${meta}.XXXXXX")
cat "$meta" > "$tmp"
printf 'test_writer=%s\n' "$2" >> "$tmp"
mv "$tmp" "$meta"
