#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fatlj.mihomo/subscriptions"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/fatlj-mihomo-subscription"
MAX_BYTES=8388608
WORK=""

if [[ ${MIHOMO_SUBSCRIPTION_TESTING:-0} == 1 ]]; then
  DATA_DIR="${MIHOMO_SUBSCRIPTION_DATA:-$DATA_DIR}"
  CACHE_ROOT="${MIHOMO_SUBSCRIPTION_CACHE:-$CACHE_ROOT}"
  MAX_BYTES="${MIHOMO_SUBSCRIPTION_MAX_BYTES:-$MAX_BYTES}"
fi

info_json() {
  local action="$1" id="$2" kind="$3" label="$4" path="$5" bytes="$6"
  jq -cn \
    --arg action "$action" \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg label "$label" \
    --arg path "$path" \
    --argjson bytes "$bytes" \
    '{ok: true, $action, $id, $kind, $label, $path, $bytes}'
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -z $WORK || ! -d $WORK ]] || rm -rf -- "$WORK"
}
trap cleanup EXIT

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

validate_size() {
  local file="$1" bytes
  bytes="$(stat -Lc %s "$file" 2>/dev/null || echo 0)"
  [[ $bytes =~ ^[0-9]+$ ]] || die "Could not determine subscription size"
  (( bytes > 0 )) || die "The subscription is empty"
  (( bytes <= MAX_BYTES )) || die "The subscription exceeds the 8 MiB limit"
  printf '%s\n' "$bytes"
}

validate_config() {
  local file="$1" validator validation_dir geoip
  validator="$(command -v mihomo 2>/dev/null || true)"
  if [[ ${MIHOMO_SUBSCRIPTION_TESTING:-0} == 1 && -n ${MIHOMO_SUBSCRIPTION_MIHOMO:-} ]]; then
    validator="$MIHOMO_SUBSCRIPTION_MIHOMO"
  fi
  [[ -n $validator && -x $validator ]] || die "Mihomo is not installed"

  validation_dir="$WORK/validation"
  mkdir -p "$validation_dir"
  for geoip in /etc/mihomo/Country.mmdb /etc/clash/Country.mmdb; do
    if [[ -s $geoip ]]; then
      ln -s -- "$geoip" "$validation_dir/Country.mmdb"
      break
    fi
  done
  if ! "$validator" -t -d "$validation_dir" -f "$file" >"$WORK/validation.log" 2>&1; then
    die "Mihomo rejected the subscription configuration"
  fi
}

command -v jq >/dev/null 2>&1 || die "Required command is missing: jq"
command -v flock >/dev/null 2>&1 || die "Required command is missing: flock"
command -v sha256sum >/dev/null 2>&1 || die "Required command is missing: sha256sum"

IFS= read -r source || die "Enter a local file path or HTTP(S) URL"
[[ -n $source ]] || die "Enter a local file path or HTTP(S) URL"
[[ $MAX_BYTES =~ ^[0-9]+$ ]] || die "Invalid subscription size limit"

umask 077
mkdir -p "$DATA_DIR" "$CACHE_ROOT"
chmod 0700 "$(dirname "$DATA_DIR")" "$DATA_DIR" "$CACHE_ROOT" 2>/dev/null || true
[[ ! -L $(dirname "$DATA_DIR") && ! -L $DATA_DIR ]] ||
  die "Subscription data directories must not be symbolic links"
[[ $(stat -Lc %d "$DATA_DIR") == $(stat -Lc %d "$CACHE_ROOT") ]] ||
  die "Subscription cache and data must be on the same filesystem"
# Downloads, validation, and committed subscription data all stay outside the
# recursively watched plugin tree, so importing cannot rebuild the panel.
WORK="$(mktemp -d "$CACHE_ROOT/import.XXXXXX")"
candidate="$WORK/config.yaml"
kind=""
label=""

case "$source" in
  http://*|https://*)
    kind=url
    label="$(safe_url_label "$source")"
    command -v curl >/dev/null 2>&1 || die "Required command is missing: curl"
    [[ $source != *$'\r'* && $source != *$'\t'* ]] || die "The subscription URL contains unsupported control characters"
    curl_config="$WORK/curl.conf"
    escaped_source="${source//\\/\\\\}"
    escaped_source="${escaped_source//\"/\\\"}"
    printf 'url = "%s"\n' "$escaped_source" >"$curl_config"
    # Deliberately preserve the user's environment and curl configuration:
    # configured proxies are honored; without one curl connects directly. The
    # URL is read from a mode-0600 config instead of appearing in curl's argv.
    if ! curl --fail --location --silent --show-error \
        --proto '=http,https' --proto-redir '=http,https' \
        --connect-timeout 10 --max-time 120 --max-filesize "$MAX_BYTES" \
        --retry 2 --retry-delay 1 --user-agent 'Mihomo' \
        --output "$candidate" --config "$curl_config" 2>"$WORK/download.log"; then
      die "Could not download the subscription"
    fi
    ;;
  *)
    kind=local
    path="$source"
    if [[ $path == \~/* ]]; then path="$HOME/${path:2}"; fi
    [[ $path == /* ]] || die "Local subscription paths must be absolute or start with ~/"
    [[ -f $path && -r $path ]] || die "The local subscription file is not readable"
    validate_size "$path" >/dev/null
    cp --reflink=auto -- "$path" "$candidate"
    ;;
esac

chmod 0600 "$candidate"
bytes="$(validate_size "$candidate")"
validate_config "$candidate"

exec 9>"$CACHE_ROOT/import.lock"
flock 9

if [[ $kind == url ]]; then
  hash="$(printf '%s' "$source" | sha256sum | awk '{print $1}')"
  id="url-$hash"
  destination="$DATA_DIR/$id"
  if [[ -d $destination ]]; then
    [[ -f $destination/source.url ]] || die "Existing URL subscription metadata is missing"
    [[ $(<"$destination/source.url") == "$source" ]] || die "Subscription URL identity collision"
    if cmp -s -- "$candidate" "$destination/config.yaml"; then
      rm -f -- "$candidate"
      action=unchanged
    else
      mv -f -- "$candidate" "$destination/config.yaml"
      action=updated
    fi
  else
    entry="$WORK/entry"
    mkdir -m 0700 "$entry"
    mv -- "$candidate" "$entry/config.yaml"
    printf '%s\n' "$source" >"$entry/source.url"
    chmod 0600 "$entry/config.yaml" "$entry/source.url"
    mv -- "$entry" "$destination"
    action=added
  fi
else
  uuid="$(< /proc/sys/kernel/random/uuid)"
  id="local-$(date +%Y%m%d-%H%M%S)-${uuid%%-*}"
  destination="$DATA_DIR/$id"
  entry="$WORK/entry"
  mkdir -m 0700 "$entry"
  mv -- "$candidate" "$entry/config.yaml"
  chmod 0600 "$entry/config.yaml"
  mv -- "$entry" "$destination"
  action=added
  label="Local subscription"
fi

info_json "$action" "$id" "$kind" "$label" "$destination/config.yaml" "$bytes"
