#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LEGACY_DIR="$PLUGIN_DIR/data/subscriptions"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fatlj.mihomo/subscriptions"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/fatlj-mihomo-subscription"

if [[ ${MIHOMO_MIGRATION_TESTING:-0} == 1 ]]; then
  LEGACY_DIR="${MIHOMO_LEGACY_SUBSCRIPTION_DATA:-$LEGACY_DIR}"
  DATA_DIR="${MIHOMO_SUBSCRIPTION_DATA:-$DATA_DIR}"
  CACHE_ROOT="${MIHOMO_SUBSCRIPTION_CACHE:-$CACHE_ROOT}"
fi

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

same_entry() {
  local left="$1" right="$2"
  [[ -f $left/config.yaml && ! -L $left/config.yaml ]] || return 1
  [[ -f $right/config.yaml && ! -L $right/config.yaml ]] || return 1
  cmp -s -- "$left/config.yaml" "$right/config.yaml" || return 1
  if [[ -e $left/source.url || -e $right/source.url ]]; then
    [[ -f $left/source.url && ! -L $left/source.url ]] || return 1
    [[ -f $right/source.url && ! -L $right/source.url ]] || return 1
    cmp -s -- "$left/source.url" "$right/source.url" || return 1
  fi
}

umask 077
mkdir -p "$CACHE_ROOT" "$(dirname "$DATA_DIR")"
chmod 0700 "$CACHE_ROOT" "$(dirname "$DATA_DIR")" 2>/dev/null || true
exec 9>"$CACHE_ROOT/migrate.lock"
flock 9

if [[ ! -d $LEGACY_DIR ]]; then
  jq -cn '{ok:true,migrated:0}'
  exit 0
fi
[[ ! -L $LEGACY_DIR && ! -L $(dirname "$DATA_DIR") ]] ||
  die "Subscription data directories must not be symbolic links"
mkdir -p "$DATA_DIR"
chmod 0700 "$DATA_DIR"

migrated=0
shopt -s nullglob
for source in "$LEGACY_DIR"/*; do
  [[ -d $source && ! -L $source ]] || die "Legacy subscription entry is invalid"
  id="${source##*/}"
  [[ -n $id && $id != .* && $id != */* ]] || die "Legacy subscription identity is invalid"
  [[ -f $source/config.yaml && ! -L $source/config.yaml ]] ||
    die "Legacy subscription configuration is invalid"
  destination="$DATA_DIR/$id"
  if [[ -e $destination ]]; then
    [[ -d $destination && ! -L $destination ]] || die "Subscription migration conflict: $id"
    same_entry "$source" "$destination" || die "Subscription migration conflict: $id"
    rm -rf -- "$source"
  else
    staging="$(mktemp -d "$(dirname "$DATA_DIR")/.fatlj-mihomo-migrate.XXXXXX")"
    cp -a -- "$source/." "$staging/"
    chmod 0700 "$staging"
    chmod 0600 "$staging/config.yaml"
    [[ ! -e $staging/source.url ]] || chmod 0600 "$staging/source.url"
    mv -- "$staging" "$destination"
    rm -rf -- "$source"
  fi
  migrated=$((migrated + 1))
done
rmdir -- "$LEGACY_DIR" 2>/dev/null || true
jq -cn --argjson migrated "$migrated" '{ok:true,$migrated}'
