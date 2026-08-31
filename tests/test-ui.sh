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
  and .version == "0.9.4"
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
for component in Panel BarIconButton KeyboardPanel PanelKeyCatcher PanelHero CursorSurface Button TextField ToggleSwitch PanelSeparator PanelSectionHeader; do
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
markers = ['("SUBSCRIPTIONS · " + root.subscriptionCount)', 'text: "CONFIG"', 'text: "BOOTSTRAP"']
assert [text.index(marker) for marker in markers] == sorted(text.index(marker) for marker in markers)
PY
grep -Fq 'validator: IntValidator { bottom: 1024; top: 65535 }' "$PANEL" || fail "runtime port range is not wired"
if grep -Fq 'draftRuntimePort !== 7890' "$PANEL" || grep -Fq 'reserved for Clash Verge' "$PANEL"; then
  fail "port 7890 is still reserved"
fi
grep -Fq 'id: runtimePortInput' "$PANEL" || fail "runtime port text input is missing"
grep -Fq 'property string draftRuntimePortText: ""' "$PANEL" || fail "runtime port flashes the default before status loads"
grep -Fq 'readonly property bool settingsDirty: settingsLoaded' "$PANEL" || fail "Apply can appear before settings load"
grep -Fq 'enabled: root.settingsLoaded && !root.runtimeBusy' "$PANEL" || fail "runtime controls are active before settings load"
grep -Fq 'placeholderText: "--"' "$PANEL" || fail "unloaded runtime port has no neutral placeholder"
grep -Fq 'anchors.horizontalCenter: parent.horizontalCenter' "$PANEL" || fail "runtime controls are not grouped like Omarchy compact settings"
grep -Fq 'text: "PORT"' "$PANEL" || fail "runtime port label does not follow Omarchy compact-label styling"
grep -Fq 'text: "ALLOW LAN"' "$PANEL" || fail "Allow LAN label does not follow Omarchy compact-label styling"
grep -Fq 'portFontMetrics.advanceWidth("00000")' "$PANEL" || fail "runtime port field is not sized for five digits"
grep -Fq 'maximumLength: 5' "$PANEL" || fail "runtime port field does not enforce five-character input"
grep -Fq 'onTextEdited: root.draftRuntimePortText = text' "$PANEL" || fail "runtime port draft does not update while typing"
grep -Fq 'draftRuntimePortText !== String(savedRuntimePort)' "$PANEL" || fail "Apply visibility does not follow typed text immediately"
grep -Fq 'id: allowLanControl' "$PANEL" || fail "port and Allow LAN are not in one config row"
grep -Fq 'checked: root.draftAllowLan' "$PANEL" || fail "Allow LAN draft toggle is not wired"
grep -Fq 'command: [root.subscriptionControlScript, "apply"]' "$PANEL" || fail "Apply is not wired to runtime control"
grep -Fq 'root.draftRuntimePortText = String(previousPort)' "$PANEL" || fail "failed Apply does not restore the previous port in the UI"
grep -Fq 'root.draftAllowLan = previousAllowLan' "$PANEL" || fail "failed Apply does not restore the previous Allow LAN value in the UI"
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
grep -Fq 'readonly property bool controllerAvailable: root.runtimeRunning' "$PANEL" || fail "latency action is not gated by the main Controller"
grep -Fq 'enabled: controllerAvailable && !latencyProc.running' "$PANEL" || fail "latency action can run without the main Controller"
grep -Fq 'onClicked: root.startLatency(' "$PANEL" || fail "group latency button is not clickable"
grep -Fq 'proxyNodeRow.latency.delayMs + " ms"' "$PANEL" || fail "node latency is not rendered beside the node"
grep -Fq 'height: Math.min(contentHeight, Style.space(320))' "$PANEL" || fail "subscription node lists are not height-bounded"
grep -Fq 'command: [root.subscriptionControlScript, "start"]' "$PANEL" || fail "node click is not connected to runtime control"
grep -Fq 'onTapped: root.startNode(proxyNodeRow.subscriptionId, proxyNodeRow.member.name)' "$PANEL" || fail "shared proxy rows are not clickable"
grep -Fq 'checked: root.runtimeRunning' "$PANEL" || fail "runtime stop switch is missing"
grep -Fq 'onToggled: root.toggleRuntime()' "$PANEL" || fail "runtime start-stop switch is not wired"
grep -Fq 'startNode(activeSubscriptionId, activeNodeName)' "$PANEL" || fail "runtime switch does not restart the saved node"
grep -Fq 'text: root.activeNodeName' "$PANEL" || fail "active node is not shown in the hero"
grep -Fq 'visible: nodeNameText.implicitWidth > nodeNameText.width && nodeNameHover.hovered' "$PANEL" || fail "elided active nodes do not use a hover tooltip"
grep -Fq 'PanelToolTip {' "$PANEL" || fail "active-node tooltip does not use Omarchy's official component"
grep -Fq 'color: root.foreground' "$PANEL" || fail "hero node does not use the official foreground color"
grep -Fq 'iconText: "󰓅"' "$PANEL" || fail "latency action does not use the official network meter icon"
grep -Fq ': "Speed Test"' "$PANEL" || fail "latency action tooltip is missing"
grep -Fq 'Layout.alignment: Qt.AlignVCenter' "$PANEL" || fail "latency action is not vertically aligned"
grep -Fq 'updateRuntimeStatistics(parsed.statistics, runtimeRunning)' "$PANEL" || fail "Controller statistics are not applied"
grep -Fq 'command: [root.subscriptionControlScript, includeDetails ? "details" : "status"]' "$PANEL" || fail "Controller details are not separated from basic status"
grep -Fq 'running: root.opened || bootstrapProc.running' "$PANEL" || fail "status polling continues while the panel is closed"
grep -Fq 'root.refreshRuntime(root.opened)' "$PANEL" || fail "Controller polling is not gated by panel visibility"
grep -Fq 'Component.onCompleted: refreshRuntime(false)' "$PANEL" || fail "bar state is not initialized after a Shell/plugin reload"
grep -Fq 'RuntimeInfoLabel { text: "Receiving" }' "$PANEL" || fail "Mihomo receiving rate is missing"
grep -Fq 'RuntimeInfoLabel { text: "Sending" }' "$PANEL" || fail "Mihomo sending rate is missing"
grep -Fq 'RuntimeInfoLabel { text: "Downloaded" }' "$PANEL" || fail "Mihomo download total is missing"
grep -Fq 'RuntimeInfoLabel { text: "Uploaded" }' "$PANEL" || fail "Mihomo upload total is missing"
grep -Fq 'RuntimeInfoLabel { text: "Connections" }' "$PANEL" || fail "Mihomo connection count is missing"
grep -Fq 'RuntimeInfoLabel { text: "Latency" }' "$PANEL" || fail "Mihomo node latency is missing"
grep -Fq 'command: [root.subscriptionControlScript, "latency"]' "$PANEL" || fail "active-node latency is not wired to the main Controller"
grep -Fq 'refreshRuntimeLatency()' "$PANEL" || fail "active-node latency is not sampled when the panel opens"
grep -Fq 'root.runtimeNodeLatencyMs > 1000' "$PANEL" || fail "slow active nodes do not trigger recommendations"
grep -Fq 'if (root.runtimeRunning) {' "$PANEL" || fail "unresponsive active nodes do not trigger recommendations"
grep -Fq 'root.clearRecommendations()' "$PANEL" || fail "healthy active nodes do not clear recommendations"
grep -Fq 'recommendProc.running = false' "$PANEL" || fail "healthy active nodes do not stop recommendation testing"
grep -Fq 'property bool cancelled: false' "$PANEL" || fail "cancelled recommendation tests can publish stale results"
grep -Fq 'pendingRequest = JSON.stringify({mode: "recommend"})' "$PANEL" || fail "recommendation background test is not wired"
grep -Fq 'text: "RECOMMEND"' "$PANEL" || fail "recommendation section is missing"
grep -Fq 'model: recommendSubscription.recommendation.top || []' "$PANEL" || fail "per-subscription recommendation Top 3 is not rendered"
grep -Fq 'height: Math.min(contentHeight, Style.space(180))' "$PANEL" || fail "recommendation list is not height-bounded"
grep -Fq 'id: recommendList' "$PANEL" || fail "recommendation scrolling region is missing"
grep -Fq 'component ProxyNodeRow: CursorSurface' "$PANEL" || fail "normal and recommended nodes do not share a row component"
[[ $(grep -c 'delegate: ProxyNodeRow {' "$PANEL") -eq 2 ]] || fail "shared proxy row is not used by both node lists"
grep -Fq 'component RuntimeInfoValue: Text' "$PANEL" || fail "Mihomo details do not use the Network-style value layout"
grep -Fq 'text: root.runtimeRunning ? "󰰐" : "󰰑"' "$PANEL" || fail "Mihomo bar state does not use the standard filled/outline M icons"
if grep -Fq 'font.weight: root.runtimeRunning' "$PANEL"; then fail "Mihomo bar icon bypasses the standard OpticalGlyph path"; fi
grep -Fq 'dimmed: root.runtimeStatusLoaded' "$PANEL" || fail "unknown runtime state is incorrectly dimmed"
grep -Fq 'active: false' "$PANEL" || fail "bar icon uses the red active treatment"
grep -Fq 'implicitWidth: button.implicitWidth' "$PANEL" || fail "bar widget does not publish its button width"
grep -Fq 'implicitHeight: button.implicitHeight' "$PANEL" || fail "bar widget does not publish its button height"
if grep -Eq '#[[:xdigit:]]{3,8}|font\.pixelSize:[[:space:]]*[0-9]|spacing:[[:space:]]*[0-9]|radius:[[:space:]]*[0-9]' "$PANEL"; then
  fail "panel contains hard-coded visual tokens"
fi

grep -Fq 'preexec_fn=set_parent_death_signal' "$LATENCY_HELPER" || fail "temporary Mihomo can survive a killed recommendation helper"

echo "ui_tests=ok official_truncated_node_tooltip=1 null_connections_zero=1 parent_death_cleanup=1 healthy_node_cancels_recommend=1 recommend_top3=1 shared_proxy_row=1 bounded_recommend_scroll=1 active_node_latency_on_open=1 one_shot_basic_status=1 no_closed_panel_polling=1 no_default_port_flash=1 on_demand_details=1 runtime_statistics=1 main_controller_latency=1 network_style_grid=1 runtime_settings=1 port_7890=1 inline_config=1 immediate_apply=1 apply_failure_reset=1 ufw_wiring=1 subscription_group_collapse=1 clickable_nodes=1 style_tokens=shared"
