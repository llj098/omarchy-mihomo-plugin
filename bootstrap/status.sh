#!/usr/bin/env bash
set -Eeuo pipefail

binary=""
package_version=""
geoip_path=""
geoip_size=0

if [[ ${MIHOMO_STATUS_TESTING:-0} == 1 ]]; then
  [[ ${MIHOMO_STATUS_BIN:-} == __missing__ ]] || binary="${MIHOMO_STATUS_BIN:-}"
  package_version="${MIHOMO_STATUS_PACKAGE_VERSION:-}"
  [[ ${MIHOMO_STATUS_GEOIP:-} == __missing__ ]] || geoip_path="${MIHOMO_STATUS_GEOIP:-}"
else
  binary="$(command -v mihomo 2>/dev/null || true)"
  package_version="$(LC_ALL=C pacman -Q mihomo 2>/dev/null | awk '{print $2}' || true)"
  if [[ -e /etc/mihomo/Country.mmdb ]]; then
    geoip_path=/etc/mihomo/Country.mmdb
  elif [[ -e /etc/clash/Country.mmdb ]]; then
    geoip_path=/etc/clash/Country.mmdb
  fi
fi

mihomo_installed=false
version_text=""
if [[ -n $binary && -x $binary ]]; then
  if version_text="$("$binary" -v 2>/dev/null | head -n1)" && [[ -n $version_text ]]; then
    mihomo_installed=true
  fi
fi

geoip_ready=false
if [[ -n $geoip_path && -e $geoip_path ]]; then
  geoip_size="$(stat -Lc %s "$geoip_path" 2>/dev/null || echo 0)"
  [[ $geoip_size =~ ^[0-9]+$ ]] || geoip_size=0
  (( geoip_size >= 1000000 )) && geoip_ready=true
fi

package_installed=false
[[ -n $package_version ]] && package_installed=true
ready=false
[[ $mihomo_installed == true && $geoip_ready == true ]] && ready=true

jq -cn \
  --arg binaryPath "$binary" \
  --arg versionText "$version_text" \
  --arg packageVersion "$package_version" \
  --arg geoipPath "$geoip_path" \
  --argjson geoipSize "$geoip_size" \
  --argjson mihomoInstalled "$mihomo_installed" \
  --argjson packageInstalled "$package_installed" \
  --argjson geoipReady "$geoip_ready" \
  --argjson ready "$ready" \
  '{
    $mihomoInstalled,
    bootstrapRequired: ($mihomoInstalled | not),
    $packageInstalled,
    $geoipReady,
    $ready,
    $binaryPath,
    $versionText,
    $packageVersion,
    $geoipPath,
    $geoipSize
  }'
