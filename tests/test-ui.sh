#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/bootstrap/status.sh"
PANEL="$ROOT/Panel.qml"
MANIFEST="$ROOT/manifest.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-ui-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$STATUS"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$STATUS"; fi
jq -e '
  .schemaVersion == 1
  and .id == "fatlj.mihomo"
  and (.kinds | index("bar-widget") != null)
  and .entryPoints.barWidget == "Panel.qml"
  and .barWidget.defaultSection == "right"
  and .barWidget.allowMultiple == false
' "$MANIFEST" >/dev/null

missing="$(env \
  MIHOMO_STATUS_TESTING=1 \
  MIHOMO_STATUS_BIN=__missing__ \
  MIHOMO_STATUS_GEOIP=__missing__ \
  "$STATUS")"
jq -e '
  .mihomoInstalled == false
  and .bootstrapRequired == true
  and .geoipReady == false
  and .ready == false
' <<<"$missing" >/dev/null

cat >"$TMP/mihomo" <<'EOF'
#!/bin/sh
echo "Mihomo Meta test-version linux amd64"
EOF
chmod +x "$TMP/mihomo"
dd if=/dev/zero of="$TMP/Country.mmdb" bs=1 count=0 seek=1000000 status=none
ready="$(env \
  MIHOMO_STATUS_TESTING=1 \
  MIHOMO_STATUS_BIN="$TMP/mihomo" \
  MIHOMO_STATUS_PACKAGE_VERSION=1.19.30-1 \
  MIHOMO_STATUS_GEOIP="$TMP/Country.mmdb" \
  "$STATUS")"
jq -e '
  .mihomoInstalled == true
  and .bootstrapRequired == false
  and .packageInstalled == true
  and .geoipReady == true
  and .ready == true
  and .packageVersion == "1.19.30-1"
' <<<"$ready" >/dev/null

# Style is inherited from Omarchy's UI kit, not reproduced with local colors,
# pixel constants, or custom popup chrome.
for component in Panel BarIconButton KeyboardPanel PanelKeyCatcher PanelHero CursorSurface Button PanelSeparator PanelSectionHeader; do
  grep -Eq "(^|[[:space:]])${component}[[:space:]]*\\{" "$PANEL" || fail "missing Omarchy UI component: $component"
done
grep -Fq 'visible: root.bootstrapAvailable' "$PANEL" || fail "Bootstrap visibility is not state-gated"
grep -Fq 'command: [root.bootstrapScript, "launch"]' "$PANEL" || fail "Bootstrap button does not invoke the reviewed script"
if grep -Eq '#[[:xdigit:]]{3,8}|font\.pixelSize:[[:space:]]*[0-9]|spacing:[[:space:]]*[0-9]|radius:[[:space:]]*[0-9]' "$PANEL"; then
  fail "panel contains hard-coded visual tokens"
fi

echo "ui_tests=ok missing_state=1 ready_state=1 omarchy_components=9 style_tokens=shared"
