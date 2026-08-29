#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/bootstrap/status.sh"
SUBSCRIPTION_IMPORT="$ROOT/subscription/import.sh"
SUBSCRIPTION_STATUS="$ROOT/subscription/status.sh"
SUBSCRIPTION_STATUS_PY="$ROOT/subscription/status.py"
SUBSCRIPTION_CONTROL="$ROOT/subscription/control.py"
LATENCY_HELPER="$ROOT/subscription/latency.py"
UFW_HELPER="$ROOT/subscription/ufw.sh"
PANEL="$ROOT/Panel.qml"
MANIFEST="$ROOT/manifest.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-ui-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$STATUS"
bash -n "$SUBSCRIPTION_IMPORT"
bash -n "$SUBSCRIPTION_STATUS"
bash -n "$UFW_HELPER"
python3 -c 'import ast, pathlib, sys; [ast.parse(pathlib.Path(path).read_text()) for path in sys.argv[1:]]' \
  "$SUBSCRIPTION_STATUS_PY" "$SUBSCRIPTION_CONTROL" "$LATENCY_HELPER"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$STATUS" "$SUBSCRIPTION_IMPORT" "$SUBSCRIPTION_STATUS" "$UFW_HELPER"
fi
jq -e '
  .schemaVersion == 1
  and .id == "fatlj.mihomo"
  and .version == "0.7.0"
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
for component in Panel BarIconButton KeyboardPanel PanelKeyCatcher PanelHero CursorSurface Button TextField NumberField Toggle PanelSeparator PanelSectionHeader; do
  grep -Eq "(^|[[:space:]])${component}[[:space:]]*\\{" "$PANEL" || fail "missing Omarchy UI component: $component"
done
grep -Fq 'visible: root.bootstrapAvailable' "$PANEL" || fail "Bootstrap visibility is not state-gated"
grep -Fq 'command: [root.bootstrapScript, "launch"]' "$PANEL" || fail "Bootstrap button does not invoke the reviewed script"
grep -Fq 'command: [root.subscriptionImportScript]' "$PANEL" || fail "subscription import is not separated from Bootstrap"
grep -Fq 'command: [root.subscriptionStatusScript]' "$PANEL" || fail "subscription status is not separated from Bootstrap"
grep -Fq 'stdinEnabled: true' "$PANEL" || fail "subscription source is exposed through argv instead of stdin"
[[ $(grep -c 'PanelSeparator {' "$PANEL") -ge 3 ]] || fail "installation, settings, and subscriptions are not visibly separated"
grep -Fq 'text: "CONFIG"' "$PANEL" || fail "config section is missing"
grep -Fq 'meta: root.mihomoInstalled ? root.packageVersion : ""' "$PANEL" || fail "Mihomo version is not under the title"
if grep -Fq 'text: "INSTALLATION"' "$PANEL"; then fail "installation section is still rendered"; fi
python3 - "$PANEL" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
markers = ['text: "STATUS"', '("SUBSCRIPTIONS · " + root.subscriptionCount)', 'text: "CONFIG"', 'text: "BOOTSTRAP"']
assert [text.index(marker) for marker in markers] == sorted(text.index(marker) for marker in markers)
PY
grep -Fq 'from: 1024' "$PANEL" || fail "runtime port minimum is not wired"
grep -Fq 'to: 65535' "$PANEL" || fail "runtime port maximum is not wired"
grep -Fq 'draftRuntimePort !== 7890' "$PANEL" || fail "Clash Verge port is not reserved"
grep -Fq 'checked: root.draftAllowLan' "$PANEL" || fail "Allow LAN draft toggle is not wired"
grep -Fq 'command: [root.subscriptionControlScript, "apply"]' "$PANEL" || fail "Apply is not wired to runtime control"
grep -Fq 'visible: root.savedAllowLan' "$PANEL" || fail "UFW review is not always shown for applied Allow LAN"
grep -Fq 'command: [root.ufwScript, "launch", String(root.savedRuntimePort)]' "$PANEL" || fail "UFW review does not use the floating-terminal helper"
grep -Fq 'text: root.subscriptionCount > 0 ? ("SUBSCRIPTIONS · " + root.subscriptionCount) : "SUBSCRIPTIONS"' "$PANEL" || fail "subscription section is missing"
grep -Fq 'model: root.subscriptions' "$PANEL" || fail "subscriptions do not own separate node lists"
grep -Fq 'property var expandedSubscriptions: ({})' "$PANEL" || fail "subscription expansion memory does not default empty"
grep -Fq 'property var expandedGroups: ({})' "$PANEL" || fail "group expansion memory does not default empty"
grep -Fq 'readonly property bool expanded: root.subscriptionExpanded(subscription.id)' "$PANEL" || fail "subscription default-collapsed state is missing"
grep -Fq 'onTapped: root.toggleSubscription(' "$PANEL" || fail "subscription header toggle is not wired"
grep -Fq 'subscriptionList.subscription.groups[0].name' "$PANEL" || fail "first group is not opened with its subscription"
grep -Fq 'model: subscriptionList.expanded ? (subscriptionList.subscription.groups || []) : []' "$PANEL" || fail "collapsed subscriptions still instantiate groups"
grep -Fq 'readonly property bool expanded: root.groupExpanded(' "$PANEL" || fail "group default-collapsed state is missing"
grep -Fq 'onTapped: root.toggleGroup(' "$PANEL" || fail "group header toggle is not wired"
grep -Fq 'model: groupList.expanded ? (groupList.group.members || []) : []' "$PANEL" || fail "collapsed groups still instantiate members"
grep -Fq 'command: [root.latencyScript]' "$PANEL" || fail "latency helper is not wired"
grep -Fq 'visible: groupList.group.directNodeCount > 0' "$PANEL" || fail "group latency button is not gated by concrete nodes"
grep -Fq 'onTapped: root.startLatency(' "$PANEL" || fail "group latency button is not clickable"
grep -Fq 'memberSurface.latency.delayMs + " ms"' "$PANEL" || fail "node latency is not rendered beside the node"
grep -Fq 'height: Math.min(contentHeight, Style.space(320))' "$PANEL" || fail "subscription node lists are not height-bounded"
grep -Fq 'command: [root.subscriptionControlScript, "start"]' "$PANEL" || fail "node click is not connected to runtime control"
grep -Fq 'subscriptionList.subscription.id, memberSurface.member.name)' "$PANEL" || fail "proxy member rows are not clickable"
grep -Fq 'text: nodeStopProc.running ? "Stopping" : "Stop Mihomo"' "$PANEL" || fail "runtime cannot be stopped from the panel"
grep -Fq 'implicitWidth: button.implicitWidth' "$PANEL" || fail "bar widget does not publish its button width"
grep -Fq 'implicitHeight: button.implicitHeight' "$PANEL" || fail "bar widget does not publish its button height"
if grep -Eq '#[[:xdigit:]]{3,8}|font\.pixelSize:[[:space:]]*[0-9]|spacing:[[:space:]]*[0-9]|radius:[[:space:]]*[0-9]' "$PANEL"; then
  fail "panel contains hard-coded visual tokens"
fi

echo "ui_tests=ok missing_state=1 ready_state=1 runtime_settings=1 ufw_wiring=1 subscription_group_collapse=1 clickable_nodes=1 style_tokens=shared"
