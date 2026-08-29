#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PLUGIN_DIR/data/subscriptions"
if [[ ${MIHOMO_SUBSCRIPTION_TESTING:-0} == 1 && -n ${MIHOMO_SUBSCRIPTION_DATA:-} ]]; then
  DATA_DIR="$MIHOMO_SUBSCRIPTION_DATA"
fi

safe_url_label() {
  local url="$1" rest authority
  rest="${url#*://}"
  authority="${rest%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  authority="${authority##*@}"
  [[ -n $authority ]] || authority="Remote subscription"
  printf '%s\n' "$authority"
}

emit_entries() {
  local directory id config kind label bytes epoch modified source
  [[ -d $DATA_DIR ]] || return 0
  shopt -s nullglob
  for directory in "$DATA_DIR"/*; do
    [[ -d $directory ]] || continue
    id="${directory##*/}"
    config="$directory/config.yaml"
    [[ -s $config ]] || continue
    kind=local
    label="Local subscription"
    if [[ -f $directory/source.url ]]; then
      source="$(<"$directory/source.url")"
      kind=url
      label="$(safe_url_label "$source")"
    fi
    bytes="$(stat -Lc %s "$config" 2>/dev/null || echo 0)"
    epoch="$(stat -Lc %Y "$config" 2>/dev/null || echo 0)"
    [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
    [[ $epoch =~ ^[0-9]+$ ]] || epoch=0
    modified="$(LC_ALL=C date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    jq -cn \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg label "$label" \
      --arg path "$config" \
      --arg modified "$modified" \
      --argjson bytes "$bytes" \
      --argjson modifiedEpoch "$epoch" \
      '{$id, $kind, $label, $path, $modified, $bytes, $modifiedEpoch}'
  done
}

entries="$(emit_entries | jq -sc 'sort_by(.modifiedEpoch) | reverse')"
jq -cn --argjson subscriptions "$entries" '{
  count: ($subscriptions | length),
  hasSubscriptions: (($subscriptions | length) > 0),
  $subscriptions
}'
