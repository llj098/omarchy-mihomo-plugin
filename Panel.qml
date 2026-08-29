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
  property var nodeRows: []
  property int subscriptionCount: 0
  property int nodeCount: 0
  property int providerCount: 0
  property int nodeParseErrorCount: 0
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
      nodeCount = Number(parsed.nodeCount || 0)
      providerCount = Number(parsed.providerCount || 0)
      var rows = []
      var parseErrors = 0
      for (var i = 0; i < subscriptions.length; i++) {
        var subscription = subscriptions[i]
        if (subscription.parseError === true) parseErrors++
        var nodes = Array.isArray(subscription.nodes) ? subscription.nodes : []
        for (var j = 0; j < nodes.length; j++) {
          rows.push({
            sectionTitle: j === 0 ? String(subscription.label || "Subscription") : "",
            name: String(nodes[j].name || "Unnamed node"),
            type: String(nodes[j].type || "unknown")
          })
        }
      }
      nodeRows = rows
      nodeParseErrorCount = parseErrors
      subscriptionStatusError = ""
    } catch (error) {
      subscriptionStatusError = "Could not read subscription status"
    }
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
    }
  }

  onBootstrapAvailableChanged: if (!bootstrapAvailable) cursorActive = false

  Component.onCompleted: {
    refreshStatus()
    refreshSubscriptions()
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

  Timer {
    interval: bootstrapProc.running ? 2000 : 30000
    running: root.opened || bootstrapProc.running
    repeat: true
    onTriggered: {
      root.refreshStatus()
      root.refreshSubscriptions()
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
    active: root.bootstrapBusy || root.subscriptionBusy
    tooltipText: root.subscriptionBusy ? "Mihomo · Importing subscription"
      : !root.statusLoaded ? "Mihomo · Checking"
      : root.ready ? "Mihomo · Ready"
      : "Mihomo · Bootstrap required"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton)
        root.refreshStatus()
      else
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

          Repeater {
            model: root.subscriptions.slice(0, 5)

            delegate: InfoPair {
              required property var modelData
              label: modelData.label
              value: modelData.parseError ? "Node parse error"
                : (modelData.nodeCount + " nodes · " + root.formatBytes(modelData.bytes))
              valueColor: modelData.parseError ? root.urgent : root.dim
            }
          }

          Text {
            visible: root.subscriptionCount > 5
            width: parent.width
            text: "+ " + (root.subscriptionCount - 5) + " more"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSectionHeader {
            visible: root.subscriptionCount > 0
            text: "NODES · " + root.nodeCount
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.subscriptionCount > 0 && root.nodeCount === 0 && root.nodeParseErrorCount === 0
            width: parent.width
            text: root.providerCount > 0 ? "No inline nodes; this configuration references proxy providers." : "No inline nodes found"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.nodeParseErrorCount > 0
            width: parent.width
            text: root.nodeParseErrorCount + " subscription configuration could not be parsed"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ListView {
            id: nodeList
            visible: root.nodeRows.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(240))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.nodeRows

            delegate: Item {
              required property var modelData
              width: ListView.view.width
              height: nodeDelegateColumn.implicitHeight

              Column {
                id: nodeDelegateColumn
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader {
                  visible: modelData.sectionTitle !== ""
                  height: visible ? implicitHeight : 0
                  text: modelData.sectionTitle
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                NodePair {
                  label: modelData.name
                  value: modelData.type.toUpperCase()
                }
              }
            }
          }

          Text {
            visible: root.nodeRows.length < root.nodeCount
            width: parent.width
            text: "+ " + (root.nodeCount - root.nodeRows.length) + " more nodes not rendered"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
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
