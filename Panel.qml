import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "fatlj.mihomo"
  ipcTarget: "fatlj.mihomo"

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/fatlj.mihomo"
  readonly property string statusScript: pluginDir + "/bootstrap/status.sh"
  readonly property string bootstrapScript: pluginDir + "/bootstrap/bootstrap.sh"
  readonly property string subscriptionStatusScript: pluginDir + "/subscription/status.sh"
  readonly property string subscriptionImportScript: pluginDir + "/subscription/import.sh"
  readonly property string subscriptionControlScript: pluginDir + "/subscription/control.py"
  readonly property string latencyScript: pluginDir + "/subscription/latency.py"
  readonly property string ufwScript: pluginDir + "/subscription/ufw.sh"

  property bool statusLoaded: false
  property string statusError: ""
  property bool mihomoInstalled: false
  property bool packageInstalled: false
  property bool geoipReady: false
  property bool ready: false
  property string binaryPath: ""
  property string versionText: ""
  property string packageVersion: ""
  property string geoipPath: ""
  property real geoipSize: 0
  property bool cursorActive: false
  property var subscriptions: []
  property int subscriptionCount: 0
  property bool runtimeRunning: false
  property string activeSubscriptionId: ""
  property string activeNodeName: ""
  property string activeNodeType: ""
  property int runtimePort: 7891
  property string runtimeBindAddress: "127.0.0.1"
  property bool settingsLoaded: false
  property int savedRuntimePort: 7891
  property bool savedAllowLan: false
  property int draftRuntimePort: 7891
  property bool draftAllowLan: false
  property string settingsError: ""
  property string settingsMessage: ""
  property var expandedSubscriptions: ({})
  property var expandedGroups: ({})
  property var latencyResults: ({})
  property string latencyBusyKey: ""
  property string latencyError: ""
  property string runtimeError: ""
  property string runtimeMessage: ""
  property string subscriptionError: ""
  property string subscriptionStatusError: ""
  property string subscriptionMessage: ""
  property bool showSubscriptionInput: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool bootstrapAvailable: statusLoaded && !mihomoInstalled
  readonly property bool bootstrapBusy: bootstrapProc.running
  readonly property bool subscriptionBusy: subscriptionImportProc.running
  readonly property bool runtimeBusy: nodeStartProc.running || nodeStopProc.running || settingsApplyProc.running
  readonly property bool settingsValid: draftRuntimePort === Math.floor(draftRuntimePort)
    && draftRuntimePort >= 1024 && draftRuntimePort <= 65535 && draftRuntimePort !== 7890
  readonly property bool settingsDirty: draftRuntimePort !== savedRuntimePort
    || draftAllowLan !== savedAllowLan
  readonly property string subscriptionFailure: subscriptionError !== "" ? subscriptionError : subscriptionStatusError
  readonly property string activeSubscriptionLabel: {
    for (var i = 0; i < subscriptions.length; i++) {
      if (subscriptions[i].id === activeSubscriptionId) return String(subscriptions[i].label || "Subscription")
    }
    return "Subscription"
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshSubscriptions() {
    if (!subscriptionStatusProc.running) subscriptionStatusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      mihomoInstalled = parsed.mihomoInstalled === true
      packageInstalled = parsed.packageInstalled === true
      geoipReady = parsed.geoipReady === true
      ready = parsed.ready === true
      binaryPath = String(parsed.binaryPath || "")
      versionText = String(parsed.versionText || "")
      packageVersion = String(parsed.packageVersion || "")
      geoipPath = String(parsed.geoipPath || "")
      geoipSize = Number(parsed.geoipSize || 0)
      statusLoaded = true
      statusError = ""
    } catch (error) {
      statusError = "Could not read Mihomo status"
    }
  }

  function applySubscriptionStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      subscriptions = Array.isArray(parsed.subscriptions) ? parsed.subscriptions : []
      subscriptionCount = Number(parsed.count || 0)
      subscriptionStatusError = ""
    } catch (error) {
      subscriptionStatusError = "Could not read subscription status"
    }
  }

  function applyRuntimeStatus(raw, resetDraft) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      runtimeRunning = parsed.running === true
      activeSubscriptionId = String(parsed.subscriptionId || "")
      activeNodeName = String(parsed.nodeName || "")
      activeNodeType = String(parsed.nodeType || "")
      runtimePort = Number(parsed.port || 7891)
      runtimeBindAddress = String(parsed.bindAddress || "127.0.0.1")
      if (parsed.settings && Number.isInteger(parsed.settings.port)
          && typeof parsed.settings.allowLan === "boolean") {
        var preserveDraft = settingsLoaded && settingsDirty && resetDraft !== true
        savedRuntimePort = parsed.settings.port
        savedAllowLan = parsed.settings.allowLan
        if (!preserveDraft) {
          draftRuntimePort = savedRuntimePort
          draftAllowLan = savedAllowLan
        }
        settingsLoaded = true
      }
    } catch (error) {
      if (runtimeError === "") runtimeError = "Could not read Mihomo runtime status"
    }
  }

  function refreshRuntime() {
    if (!runtimeStatusProc.running) runtimeStatusProc.running = true
  }

  function startNode(subscriptionId, nodeName) {
    if (runtimeBusy || !subscriptionId || !nodeName) return
    runtimeError = ""
    runtimeMessage = "Starting " + nodeName
    nodeStartProc.pendingRequest = JSON.stringify({
      subscriptionId: subscriptionId,
      nodeName: nodeName
    })
    nodeStartProc.running = true
  }

  function stopRuntime() {
    if (runtimeBusy || !runtimeRunning) return
    runtimeError = ""
    runtimeMessage = "Stopping Mihomo"
    nodeStopProc.running = true
  }

  function applyRuntimeSettings() {
    if (runtimeBusy || !settingsValid || !settingsDirty) return
    settingsError = ""
    settingsMessage = "Applying runtime settings"
    settingsApplyProc.pendingRequest = JSON.stringify({
      port: draftRuntimePort,
      allowLan: draftAllowLan
    })
    settingsApplyProc.running = true
  }

  function reviewUfw() {
    if (!savedAllowLan || ufwProc.running) return
    settingsError = ""
    ufwProc.running = true
  }

  function subscriptionExpanded(subscriptionId) {
    return expandedSubscriptions[subscriptionId] === true
  }

  function toggleSubscription(subscriptionId, firstGroupName) {
    var opening = !subscriptionExpanded(subscriptionId)
    var next = {}
    for (var key in expandedSubscriptions) next[key] = expandedSubscriptions[key]
    next[subscriptionId] = opening
    expandedSubscriptions = next
    if (opening && firstGroupName) {
      var groupKey = groupExpansionKey(subscriptionId, firstGroupName)
      var groups = {}
      for (var current in expandedGroups) groups[current] = expandedGroups[current]
      groups[groupKey] = true
      expandedGroups = groups
    }
  }

  function groupExpansionKey(subscriptionId, groupName) {
    return subscriptionId + "\u001f" + groupName
  }

  function groupExpanded(subscriptionId, groupName) {
    return expandedGroups[groupExpansionKey(subscriptionId, groupName)] === true
  }

  function toggleGroup(subscriptionId, groupName) {
    var key = groupExpansionKey(subscriptionId, groupName)
    var next = {}
    for (var current in expandedGroups) next[current] = expandedGroups[current]
    next[key] = !groupExpanded(subscriptionId, groupName)
    expandedGroups = next
  }

  function latencyKey(subscriptionId, groupName, nodeName) {
    return subscriptionId + "\u001f" + groupName + "\u001f" + nodeName
  }

  function nodeLatency(subscriptionId, groupName, nodeName) {
    return latencyResults[latencyKey(subscriptionId, groupName, nodeName)] || null
  }

  function startLatency(subscriptionId, groupName) {
    if (latencyProc.running) return
    latencyError = ""
    latencyBusyKey = groupExpansionKey(subscriptionId, groupName)
    latencyProc.pendingRequest = JSON.stringify({subscriptionId: subscriptionId, groupName: groupName})
    latencyProc.running = true
  }

  function formatBytes(bytes) {
    var value = Number(bytes || 0)
    if (value < 1024) return value + " B"
    if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KiB"
    return (value / (1024 * 1024)).toFixed(1) + " MiB"
  }

  function launchBootstrap() {
    if (!bootstrapAvailable || bootstrapProc.running) return
    statusError = ""
    bootstrapProc.running = true
    close()
  }

  function openSubscriptionInput() {
    if (subscriptionBusy) return
    subscriptionError = ""
    subscriptionMessage = ""
    showSubscriptionInput = true
    Qt.callLater(function() { subscriptionInput.forceActiveFocus() })
  }

  function cancelSubscriptionInput() {
    subscriptionInput.text = ""
    subscriptionInput.focus = false
    showSubscriptionInput = false
    subscriptionError = ""
  }

  function importSubscription() {
    var source = String(subscriptionInput.text || "")
    if (source.length === 0 || subscriptionBusy) {
      if (source.length === 0) subscriptionError = "Enter a local file path or HTTP(S) URL"
      return
    }
    subscriptionError = ""
    subscriptionMessage = ""
    subscriptionImportProc.pendingSource = source
    subscriptionInput.focus = false
    subscriptionImportProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = bootstrapAvailable
      refreshStatus()
      refreshSubscriptions()
      refreshRuntime()
    }
  }

  onBootstrapAvailableChanged: if (!bootstrapAvailable) cursorActive = false

  Component.onCompleted: {
    refreshStatus()
    refreshSubscriptions()
    refreshRuntime()
  }

  Process {
    id: statusProc
    command: [root.statusScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.statusError = String(statusStderr.text || "Mihomo status check failed").trim()
        root.statusLoaded = true
      }
    }
  }

  Process {
    id: bootstrapProc
    command: [root.bootstrapScript, "launch"]
    onExited: function(exitCode) {
      if (exitCode !== 0 && exitCode !== 130)
        root.statusError = "Bootstrap could not be opened"
      root.refreshStatus()
    }
  }

  Process {
    id: subscriptionStatusProc
    command: [root.subscriptionStatusScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySubscriptionStatus(text)
    }
    stderr: StdioCollector {
      id: subscriptionStatusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.subscriptionStatusError = String(subscriptionStatusStderr.text || "Subscription status check failed").trim()
    }
  }

  Process {
    id: subscriptionImportProc
    property string pendingSource: ""
    command: [root.subscriptionImportScript]
    stdinEnabled: true
    stdout: StdioCollector {
      id: subscriptionImportStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: subscriptionImportStderr
      waitForEnd: true
    }
    onStarted: {
      write(pendingSource + "\n")
      pendingSource = ""
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          var result = JSON.parse(String(subscriptionImportStdout.text || "{}"))
          root.subscriptionMessage = result.action === "updated" ? "Subscription updated" : "Subscription added"
          root.subscriptionError = ""
          subscriptionInput.text = ""
          root.showSubscriptionInput = false
        } catch (error) {
          root.subscriptionError = "Subscription was imported but its result could not be read"
        }
      } else {
        root.subscriptionError = String(subscriptionImportStderr.text || "Subscription import failed").trim()
      }
      root.refreshSubscriptions()
    }
  }

  Process {
    id: runtimeStatusProc
    command: [root.subscriptionControlScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRuntimeStatus(text)
    }
    stderr: StdioCollector {
      id: runtimeStatusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.runtimeError === "")
        root.runtimeError = String(runtimeStatusStderr.text || "Mihomo runtime status failed").trim()
    }
  }

  Process {
    id: nodeStartProc
    property string pendingRequest: ""
    command: [root.subscriptionControlScript, "start"]
    stdinEnabled: true
    stdout: StdioCollector {
      id: nodeStartStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: nodeStartStderr
      waitForEnd: true
    }
    onStarted: {
      write(pendingRequest + "\n")
      pendingRequest = ""
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          var result = JSON.parse(String(nodeStartStdout.text || "{}"))
          root.applyRuntimeStatus(JSON.stringify(result))
          root.runtimeMessage = "Running " + result.nodeName + " on " + result.bindAddress + ":" + result.port
          root.runtimeError = ""
        } catch (error) {
          root.runtimeError = "Mihomo started but its runtime status could not be read"
        }
      } else {
        root.runtimeMessage = ""
        root.runtimeError = String(nodeStartStderr.text || "Could not start the selected node").trim()
      }
      root.refreshRuntime()
    }
  }

  Process {
    id: settingsApplyProc
    property string pendingRequest: ""
    command: [root.subscriptionControlScript, "apply"]
    stdinEnabled: true
    stdout: StdioCollector {
      id: settingsApplyStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: settingsApplyStderr
      waitForEnd: true
    }
    onStarted: {
      write(pendingRequest + "\n")
      pendingRequest = ""
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          var result = JSON.parse(String(settingsApplyStdout.text || "{}"))
          root.applyRuntimeStatus(JSON.stringify(result), true)
          root.settingsMessage = result.restarted === true
            ? "Settings applied; Mihomo restarted"
            : "Settings saved for the next start"
          root.settingsError = ""
        } catch (error) {
          root.settingsError = "Settings were applied but their status could not be read"
        }
      } else {
        root.settingsMessage = ""
        root.settingsError = String(settingsApplyStderr.text || "Could not apply runtime settings").trim()
      }
      root.refreshRuntime()
    }
  }

  Process {
    id: ufwProc
    command: [root.ufwScript, "launch", String(root.savedRuntimePort)]
    onExited: function(exitCode) {
      if (exitCode !== 0 && exitCode !== 130)
        root.settingsError = "UFW review could not be opened"
    }
  }

  Process {
    id: nodeStopProc
    command: [root.subscriptionControlScript, "stop"]
    stdout: StdioCollector {
      id: nodeStopStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: nodeStopStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyRuntimeStatus(String(nodeStopStdout.text || "{}"))
        root.runtimeMessage = "Mihomo stopped"
        root.runtimeError = ""
      } else {
        root.runtimeMessage = ""
        root.runtimeError = String(nodeStopStderr.text || "Could not stop Mihomo").trim()
      }
      root.refreshRuntime()
    }
  }

  Process {
    id: latencyProc
    property string pendingRequest: ""
    command: [root.latencyScript]
    stdinEnabled: true
    stdout: StdioCollector { id: latencyStdout; waitForEnd: true }
    stderr: StdioCollector { id: latencyStderr; waitForEnd: true }
    onStarted: {
      write(pendingRequest + "\n")
      pendingRequest = ""
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          var result = JSON.parse(String(latencyStdout.text || "{}"))
          var next = {}
          for (var key in root.latencyResults) next[key] = root.latencyResults[key]
          for (var i = 0; i < result.results.length; i++) {
            var item = result.results[i]
            next[root.latencyKey(result.subscriptionId, result.groupName, item.name)] = item
          }
          root.latencyResults = next
          root.latencyError = ""
        } catch (error) {
          root.latencyError = "Latency result could not be read"
        }
      } else {
        root.latencyError = String(latencyStderr.text || "Latency test failed").trim()
      }
      root.latencyBusyKey = ""
    }
  }

  Timer {
    interval: (bootstrapProc.running || root.runtimeBusy || root.runtimeRunning) ? 2000 : 30000
    running: root.opened || bootstrapProc.running || root.runtimeRunning
    repeat: true
    onTriggered: {
      root.refreshStatus()
      root.refreshSubscriptions()
      root.refreshRuntime()
    }
  }

  // Bar widgets must publish the button's implicit geometry. Anchoring the
  // button alone does not give the plugin slot a width, so the icon would be
  // loaded but occupy a zero-width slot.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "M"
    fontSize: Style.font.title
    dimmed: !(root.runtimeRunning || root.runtimeBusy || root.subscriptionBusy || root.bootstrapBusy)
    active: false
    tooltipText: root.runtimeBusy ? "Mihomo · Changing runtime"
      : root.runtimeRunning ? ("Mihomo · " + root.activeNodeName + " · " + root.runtimeBindAddress + ":" + root.runtimePort)
      : root.subscriptionBusy ? "Mihomo · Importing subscription"
      : !root.statusLoaded ? "Mihomo · Checking"
      : root.ready ? "Mihomo · Ready"
      : "Mihomo · Bootstrap required"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) {
        root.refreshStatus()
        root.refreshSubscriptions()
        root.refreshRuntime()
      } else
        root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: subscriptionInput.activeFocus || runtimePortField.field.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.bootstrapAvailable) root.cursorActive = true
      }
      onActivateRequested: if (root.cursorActive && root.bootstrapAvailable) root.launchBootstrap()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Mihomo"
          meta: root.mihomoInstalled ? root.packageVersion : ""
          detail: ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.ready ? 1.0 : 0.5
          trailingControl: Component {
            Row {
              visible: root.runtimeRunning
              spacing: Style.space(6)

              Column {
                id: runtimeTextColumn
                spacing: Style.space(2)

                Text {
                  width: Math.min(implicitWidth, Style.space(150))
                  text: root.activeSubscriptionLabel + ":" + root.activeNodeName
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideLeft
                }

                Text {
                  width: parent.width
                  text: root.runtimeBindAddress + ":" + root.runtimePort
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideLeft
                }
              }

              CursorSurface {
                width: stopLabel.implicitWidth + Style.space(12)
                height: runtimeTextColumn.implicitHeight
                foreground: root.foreground
                bordered: true
                hasCursor: stopHover.hovered
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: stopLabel
                  anchors.centerIn: parent
                  text: nodeStopProc.running ? "…" : "Stop"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                HoverHandler { id: stopHover }
                TapHandler {
                  enabled: !root.runtimeBusy
                  onTapped: root.stopRuntime()
                }
              }
            }
          }
          iconComponent: Component {
            Text {
              text: "󰖟"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }
        Text {
          visible: root.statusError !== ""
          width: parent.width
          text: root.statusError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
        Text {
          visible: root.runtimeError !== ""
          width: parent.width
          text: root.runtimeError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
        PanelSeparator {
          visible: root.mihomoInstalled
          foreground: root.foreground
        }
        Column {
          visible: root.mihomoInstalled
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.subscriptionCount > 0 ? ("SUBSCRIPTIONS · " + root.subscriptionCount) : "SUBSCRIPTIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.subscriptionCount === 0 && root.subscriptionFailure === ""
            width: parent.width
            text: "No subscriptions imported"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Flickable {
            id: subscriptionLists
            visible: root.subscriptionCount > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(320))
            contentWidth: width
            contentHeight: subscriptionListsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: subscriptionListsColumn
              width: subscriptionLists.width
              spacing: Style.space(10)

              Repeater {
                model: root.subscriptions

                delegate: Column {
                  id: subscriptionList
                  required property var modelData
                  required property int index
                  readonly property var subscription: modelData
                  readonly property bool expanded: root.subscriptionExpanded(subscription.id)
                  width: subscriptionListsColumn.width
                  spacing: Style.space(4)

                  PanelSeparator {
                    visible: subscriptionList.index > 0
                    height: visible ? implicitHeight : 0
                    foreground: root.foreground
                  }

                  CursorSurface {
                    id: subscriptionHeaderSurface
                    width: parent.width
                    height: Math.max(subscriptionHeader.implicitHeight, subscriptionMeta.implicitHeight)
                      + Style.spacing.controlGap
                    foreground: root.foreground
                    hasCursor: subscriptionHeaderHover.hovered

                    PanelSectionHeader {
                      id: subscriptionHeader
                      text: subscriptionList.subscription.label
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: subscriptionMeta
                      text: (subscriptionList.expanded ? "▾ " : "▸ ")
                        + subscriptionList.subscription.groupCount
                        + (subscriptionList.subscription.groupCount === 1 ? " GROUP · " : " GROUPS · ")
                        + subscriptionList.subscription.nodeCount + " NODES"
                        + (subscriptionList.subscription.parseError ? " · PARSE ERROR" : "")
                      color: subscriptionList.subscription.parseError ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    HoverHandler { id: subscriptionHeaderHover }
                    TapHandler {
                      onTapped: root.toggleSubscription(
                        subscriptionList.subscription.id,
                        subscriptionList.subscription.groups.length > 0
                          ? subscriptionList.subscription.groups[0].name : "")
                    }
                  }

                  Text {
                    visible: subscriptionList.expanded
                      && subscriptionList.subscription.groupCount === 0
                      && !subscriptionList.subscription.parseError
                    width: parent.width
                    text: "No proxy groups found"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Repeater {
                    model: subscriptionList.expanded ? (subscriptionList.subscription.groups || []) : []

                    delegate: Column {
                      id: groupList
                      required property var modelData
                      readonly property var group: modelData
                      readonly property bool expanded: root.groupExpanded(
                        subscriptionList.subscription.id, group.name)
                      width: subscriptionList.width
                      spacing: Style.space(4)

                      Row {
                        width: parent.width
                        spacing: Style.space(6)

                        CursorSurface {
                          id: groupHeaderSurface
                          width: parent.width - groupTestButton.width - parent.spacing
                          height: Math.max(groupHeader.implicitHeight, groupMeta.implicitHeight)
                            + Style.spacing.controlGap
                          foreground: root.foreground
                          hasCursor: groupHeaderHover.hovered

                          PanelSectionHeader {
                            id: groupHeader
                            text: groupList.group.name
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(14)
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            id: groupMeta
                            text: (groupList.expanded ? "▾ " : "▸ ")
                              + groupList.group.type.toUpperCase() + " · "
                              + groupList.group.memberCount
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(6)
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          HoverHandler { id: groupHeaderHover }
                          TapHandler {
                            onTapped: root.toggleGroup(
                              subscriptionList.subscription.id, groupList.group.name)
                          }
                        }

                        CursorSurface {
                          id: groupTestButton
                          readonly property bool testing: root.latencyBusyKey === root.groupExpansionKey(
                            subscriptionList.subscription.id, groupList.group.name)
                          visible: groupList.group.directNodeCount > 0
                          width: visible ? groupTestLabel.implicitWidth + Style.space(14) : 0
                          height: groupHeaderSurface.height
                          foreground: root.foreground
                          bordered: true
                          hasCursor: groupTestHover.hovered
                          opacity: latencyProc.running && !testing ? 0.5 : 1.0

                          Text {
                            id: groupTestLabel
                            anchors.centerIn: parent
                            text: groupTestButton.testing ? "Testing" : "Speed Test"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }

                          HoverHandler { id: groupTestHover }
                          TapHandler {
                            enabled: !latencyProc.running
                            onTapped: root.startLatency(
                              subscriptionList.subscription.id, groupList.group.name)
                          }
                        }
                      }

                      Repeater {
                        model: groupList.expanded ? (groupList.group.members || []) : []

                        delegate: CursorSurface {
                          id: memberSurface
                          required property var modelData
                          readonly property var member: modelData
                          readonly property bool isProxy: member.kind === "proxy"
                          readonly property var latency: root.nodeLatency(
                            subscriptionList.subscription.id, groupList.group.name, member.name)
                          width: groupList.width
                          height: memberPair.implicitHeight + Style.spacing.controlGap
                          foreground: root.foreground
                          hasCursor: memberSurface.isProxy && memberHover.hovered
                          current: memberSurface.isProxy
                            && root.runtimeRunning
                            && root.activeSubscriptionId === subscriptionList.subscription.id
                            && root.activeNodeName === memberSurface.member.name
                          opacity: memberSurface.isProxy ? (root.runtimeBusy ? 0.6 : 1.0) : 0.65

                          NodePair {
                            id: memberPair
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(22)
                            anchors.rightMargin: Style.space(6)
                            label: memberSurface.member.name
                            value: {
                              var parts = [memberSurface.member.type.toUpperCase()]
                              if (memberSurface.current) parts.push("ACTIVE")
                              if (memberSurface.latency) {
                                parts.push(memberSurface.latency.status === "ok"
                                  ? (memberSurface.latency.delayMs + " ms") : "TIMEOUT")
                              }
                              return parts.join(" · ")
                            }
                          }

                          HoverHandler { id: memberHover }
                          TapHandler {
                            enabled: memberSurface.isProxy && !root.runtimeBusy
                            onTapped: root.startNode(
                              subscriptionList.subscription.id, memberSurface.member.name)
                          }
                        }
                      }

                      Text {
                        visible: groupList.expanded && groupList.group.membersTruncated > 0
                        width: parent.width
                        text: "+ " + groupList.group.membersTruncated + " more nodes not rendered"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.latencyError !== ""
            width: parent.width
            text: root.latencyError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.subscriptionMessage !== ""
            width: parent.width
            text: root.subscriptionMessage
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.subscriptionFailure !== ""
            width: parent.width
            text: root.subscriptionFailure
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.showSubscriptionInput
            width: parent.width
            text: "Add subscription"
            iconText: "󰐕"
            bordered: true
            enabled: !root.subscriptionBusy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSubscriptionInput()
          }

          Column {
            visible: root.showSubscriptionInput
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: subscriptionInput
              width: parent.width
              enabled: !root.subscriptionBusy
              placeholderText: "Local path or HTTP(S) URL"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.importSubscription()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelSubscriptionInput()
                  event.accepted = true
                }
              }
            }

            Text {
              visible: subscriptionInput.text.startsWith("http://")
              width: parent.width
              text: "Plain HTTP does not encrypt the subscription address or content."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Cancel"
                bordered: true
                enabled: !root.subscriptionBusy
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.cancelSubscriptionInput()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.subscriptionBusy ? "Importing" : "Import"
                iconText: root.subscriptionBusy ? "󰦖" : "󰋺"
                iconSpinning: root.subscriptionBusy
                bordered: true
                enabled: !root.subscriptionBusy && subscriptionInput.text.length > 0
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.importSubscription()
              }
            }
          }
        }
        PanelSeparator {
          visible: root.mihomoInstalled
          foreground: root.foreground
        }
        Column {
          visible: root.mihomoInstalled
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONFIG"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          NumberField {
            id: runtimePortField
            width: parent.width
            label: "Mixed port"
            from: 1024
            to: 65535
            value: root.draftRuntimePort
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModified: function(value) { root.draftRuntimePort = value }
          }

          Text {
            visible: root.draftRuntimePort === 7890
            width: parent.width
            text: "Port 7890 is reserved for Clash Verge."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Toggle {
            width: parent.width
            label: "Allow LAN"
            description: "Bind the mixed port to all interfaces instead of localhost."
            checked: root.draftAllowLan
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.draftAllowLan = !root.draftAllowLan
          }

          Button {
            visible: root.settingsDirty || settingsApplyProc.running
            width: parent.width
            text: settingsApplyProc.running ? "Applying" : "Apply"
            iconText: settingsApplyProc.running ? "󰦖" : "󰑐"
            iconSpinning: settingsApplyProc.running
            bordered: true
            enabled: !root.runtimeBusy && root.settingsValid && root.settingsDirty
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.applyRuntimeSettings()
          }

          Button {
            visible: root.savedAllowLan
            width: parent.width
            text: "Review UFW rule for port " + root.savedRuntimePort
            iconText: "󰒃"
            bordered: true
            enabled: !ufwProc.running
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.reviewUfw()
          }

          Text {
            visible: root.settingsMessage !== ""
            width: parent.width
            text: root.settingsMessage
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.settingsError !== ""
            width: parent.width
            text: root.settingsError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
        PanelSeparator {
          visible: root.bootstrapAvailable
          foreground: root.foreground
        }
        Column {
          visible: root.bootstrapAvailable
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "BOOTSTRAP"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          CursorSurface {
            visible: root.bootstrapAvailable
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "Mihomo is not installed. Bootstrap uses signed packages from ranked official mainland mirrors."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          Button {
            visible: root.bootstrapAvailable
            width: parent.width
            text: root.bootstrapBusy ? "Bootstrap opened" : "Bootstrap"
            iconText: root.bootstrapBusy ? "󰦖" : "󰇚"
            iconSpinning: root.bootstrapBusy
            bordered: true
            enabled: !root.bootstrapBusy
            hasCursor: root.cursorActive
            foreground: root.foreground
            fontFamily: root.fontFamily
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            onClicked: root.launchBootstrap()
            onHovered: function(isHovered) {
              if (isHovered) root.cursorActive = true
            }
          }
        }

      }
    }
  }

  component NodePair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      width: Math.max(0, parent.width - nodeType.width - parent.spacing)
      text: parent.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: nodeType
      width: Math.min(implicitWidth, parent.width * 0.28)
      text: parent.value
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.dim

    width: parent.width
    spacing: Style.space(8)

    Text {
      text: parent.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideLeft
      width: Math.min(implicitWidth, parent.width * 0.68)
    }
  }
}
