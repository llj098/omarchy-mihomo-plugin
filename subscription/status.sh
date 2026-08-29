#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to read Mihomo subscriptions" >&2
  exit 1
}
exec python3 "$SCRIPT_DIR/status.py"
