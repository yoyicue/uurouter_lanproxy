#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 0 ]; then
  cmd="$*"
else
  cmd="$(cat)"
fi

/usr/bin/expect "$SCRIPT_DIR/scripts/openwrt2_serial_exec.expect" "$cmd"
