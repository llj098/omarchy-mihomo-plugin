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
  readonly property bool runtimeBusy: nodeStartProc.running || nodeStopProc.running
  readonly property string subscriptionFailure: subscriptionError !== "" ? subscriptionError : subscriptionStatusError
  readonly property string heroMeta: {
    if (!statusLoaded && statusError === "") return "Checking installation"
    if (statusError !== "") return "Status unavailable"
    if (!mihomoInstalled) return "Bootstrap required"
    if (!geoipReady) return "GeoIP missing"
    return "Mihomo and GeoIP are ready"
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

  function applyRuntimeStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      runtimeRunning = parsed.running === true
      activeSubscriptionId = String(parsed.subscriptionId || "")
      activeNodeName = String(parsed.nodeName || "")
      activeNodeType = String(parsed.nodeType || "")
      runtimePort = Number(parsed.port || 7891)
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
          root.runtimeMessage = "Running " + result.nodeName + " on 127.0.0.1:" + result.port
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
    dimmed: root.statusLoaded && !root.ready
    active: root.bootstrapBusy || root.subscriptionBusy || root.runtimeBusy || root.runtimeRunning
    tooltipText: root.runtimeBusy ? "Mihomo · Changing node"
      : root.runtimeRunning ? ("Mihomo · " + root.activeNodeName + " · 127.0.0.1:" + root.runtimePort)
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
      blocked: subscriptionInput.activeFocus
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
          meta: root.heroMeta
          detail: root.packageVersion
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.ready ? 1.0 : 0.5
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

        PanelSeparator {
          visible: root.mihomoInstalled
          foreground: root.foreground
        }

        Column {
          visible: root.mihomoInstalled
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "INSTALLATION"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          InfoPair {
            label: "Binary"
            value: root.binaryPath || "Unavailable"
          }

          InfoPair {
            label: "Package"
            value: root.packageInstalled ? ("mihomo " + root.packageVersion) : "Local installation"
          }

          InfoPair {
            label: "GeoIP"
            value: root.geoipReady ? ("Ready · " + root.formatBytes(root.geoipSize)) : "Missing"
            valueColor: root.geoipReady ? root.dim : root.urgent
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

          InfoPair {
            visible: root.runtimeRunning
            label: "Runtime"
            value: root.activeNodeName + " · 127.0.0.1:" + root.runtimePort
            valueColor: root.foreground
          }

          Button {
            visible: root.runtimeRunning
            width: parent.width
            text: root.runtimeBusy ? "Stopping" : "Stop Mihomo"
            iconText: root.runtimeBusy ? "󰦖" : "󰓛"
            iconSpinning: root.runtimeBusy
            bordered: true
            enabled: !root.runtimeBusy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.stopRuntime()
          }

          Text {
            visible: root.runtimeMessage !== ""
            width: parent.width
            text: root.runtimeMessage
            color: root.dim
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
                  width: subscriptionListsColumn.width
                  spacing: Style.space(4)

                  PanelSeparator {
                    visible: subscriptionList.index > 0
                    height: visible ? implicitHeight : 0
                    foreground: root.foreground
                  }

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(subscriptionHeader.implicitHeight, subscriptionMeta.implicitHeight)

                    PanelSectionHeader {
                      id: subscriptionHeader
                      text: subscriptionList.subscription.label
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: subscriptionMeta
                      text: subscriptionList.subscription.parseError ? "PARSE ERROR"
                        : (subscriptionList.subscription.nodeCount + " NODES")
                      color: subscriptionList.subscription.parseError ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Text {
                    visible: subscriptionList.subscription.nodeCount === 0 && !subscriptionList.subscription.parseError
                    width: parent.width
                    text: subscriptionList.subscription.providerCount > 0
                      ? "No inline nodes; this configuration references proxy providers."
                      : "No inline nodes found"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Repeater {
                    model: subscriptionList.subscription.nodes || []

                    delegate: CursorSurface {
                      id: nodeSurface
                      required property var modelData
                      readonly property var node: modelData
                      width: subscriptionList.width
                      height: nodePair.implicitHeight + Style.spacing.controlGap
                      foreground: root.foreground
                      hasCursor: nodeHover.hovered
                      current: root.runtimeRunning
                        && root.activeSubscriptionId === subscriptionList.subscription.id
                        && root.activeNodeName === nodeSurface.node.name
                      opacity: root.runtimeBusy ? 0.6 : 1.0

                      NodePair {
                        id: nodePair
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(6)
                        anchors.rightMargin: Style.space(6)
                        label: nodeSurface.node.name
                        value: nodeSurface.current ? (nodeSurface.node.type.toUpperCase() + " · ACTIVE")
                          : nodeSurface.node.type.toUpperCase()
                      }

                      HoverHandler { id: nodeHover }
                      TapHandler {
                        enabled: !root.runtimeBusy
                        onTapped: root.startNode(subscriptionList.subscription.id, nodeSurface.node.name)
                      }
                    }
                  }

                  Text {
                    visible: subscriptionList.subscription.nodesTruncated > 0
                    width: parent.width
                    text: "+ " + subscriptionList.subscription.nodesTruncated + " more nodes not rendered"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
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
            text: root.subscriptionCount > 0 ? "Add another subscription" : "Add subscription"
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
