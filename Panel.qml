import QtQuick
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool bootstrapAvailable: statusLoaded && !mihomoInstalled
  readonly property bool bootstrapBusy: bootstrapProc.running
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

  onOpenedChanged: {
    if (opened) {
      cursorActive = bootstrapAvailable
      refreshStatus()
    }
  }

  onBootstrapAvailableChanged: if (!bootstrapAvailable) cursorActive = false

  Component.onCompleted: refreshStatus()

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

  Timer {
    interval: bootstrapProc.running ? 2000 : 30000
    running: root.opened || bootstrapProc.running
    repeat: true
    onTriggered: root.refreshStatus()
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
    text: "󰖟"
    dimmed: root.statusLoaded && !root.ready
    active: root.bootstrapBusy
    tooltipText: !root.statusLoaded ? "Mihomo · Checking"
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
            text: "Mihomo is not installed. Bootstrap uses signed packages from the TUNA and USTC China mirrors."
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
      }
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
