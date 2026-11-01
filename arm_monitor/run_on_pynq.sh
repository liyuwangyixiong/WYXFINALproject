#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
exec python3 "$app_dir/monitor.py" "$@"
