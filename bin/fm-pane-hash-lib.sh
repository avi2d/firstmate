#!/usr/bin/env bash
# Usage (sourced, after bin/fm-backend.sh):
#   fm_pane_stale_hash <backend> <harness> <target> <label> <tail40>

fm_pane_hash_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

fm_pane_stale_hash() {  # <backend> <harness> <target> <label> <tail40>
  printf '%s' "$5" | fm_pane_hash_digest
}
