#!/usr/bin/env bash
# Usage: fm-task-record.sh [--aggregate] [--kind KIND] [--repo REPO] [--mode MODE] [--size-band BAND]
set -eu

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$script_dir/fm-task-record.py" "$@"
