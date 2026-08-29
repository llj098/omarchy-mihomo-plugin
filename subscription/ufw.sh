#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

validate_port() {
  local port="${1:-}"
  [[ $port =~ ^[0-9]+$ ]] || die "port must be an integer from 1024 to 65535"
  (( 10#$port >= 1024 && 10#$port <= 65535 )) || die "port must be an integer from 1024 to 65535"
}

review_ufw() {
  local port="$1"
  validate_port "$port"
  command -v ufw >/dev/null 2>&1 || die "ufw is not installed"
  command -v gum >/dev/null 2>&1 || die "gum is not installed"

  gum style --border rounded --padding "1 2" \
    "UFW rule review" \
    "ufw allow $port/tcp allows all UFW-accepted sources to reach this port."
  if ! gum confirm --default=false \
      "Run sudo ufw status, then sudo ufw allow $port/tcp?"; then
    echo "UFW change cancelled"
    exit 130
  fi

  sudo ufw status
  sudo ufw allow "$port/tcp"
}

launch_popup() {
  local port="$1" self command
  validate_port "$port"
  command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1 ||
    die "Omarchy popup launcher is unavailable"
  self="$(realpath -- "$0")"
  printf -v command '%q ' "$self" review "$port"
  exec omarchy-launch-floating-terminal-with-presentation "$command"
}

case "${1:-}" in
  launch)
    [[ $# == 2 ]] || die "usage: ufw.sh launch PORT"
    launch_popup "$2"
    ;;
  review)
    [[ $# == 2 ]] || die "usage: ufw.sh review PORT"
    review_ufw "$2"
    ;;
  *) die "usage: ufw.sh launch|review PORT" ;;
esac
