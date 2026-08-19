import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "jwhall.omanodes"
  ipcTarget: "jwhall.omanodes"
  manageIpc: false

  property string focusSection: "header"
  property int networkIndex: 0
  property bool cursorActive: false
  // Network row awaiting leave confirmation; non-null opens the dialog.
  property var pendingLeave: null
  // Network the info button was clicked on; non-null opens the status window.
  property var infoNetwork: null
  property bool joinWindowOpen: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool anyOk: {
    for (var i = 0; i < zerotier.networks.length; i++) {
      if (zerotier.networks[i].status === "OK") return true
    }
    return false
  }
  readonly property color iconColor: anyOk ? foreground : dim
  readonly property color barIconColor: zerotier.lastError !== ""
    ? (bar ? bar.urgent : Color.urgent)
    : (anyOk ? barForeground : Qt.darker(barForeground, 1.55))
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  readonly property string joinNwid: joinField.value.trim()
  readonly property bool joinValid: /^[0-9a-fA-F]{16}$/.test(joinNwid)
  readonly property bool joinAlreadyMember: joinValid && zerotier.findByNwid(joinNwid) !== null
  readonly property bool joinAccepted: joinValid && !joinAlreadyMember
  readonly property string joinHintText: joinNwid === ""
    ? "16-character hex network ID"
    : (!joinValid
      ? "Must be exactly 16 hex characters"
      : (joinAlreadyMember ? "Already a member of this network" : "Ready to join"))

  // The list can reorder as networks are added/removed, so the cursor tracks
  // the network it was on by ID, not by array index.
  property string cursorNwid: ""

  function rememberCursor() {
    var n = selectedNetwork()
    cursorNwid = n ? String(n.nwid) : ""
  }

  function restoreCursor() {
    if (focusSection === "networks" && cursorNwid !== "") {
      for (var i = 0; i < zerotier.networks.length; i++) {
        if (zerotier.networks[i].nwid === cursorNwid) {
          networkIndex = i
          break
        }
      }
    }
    ensureCursor()
  }

  function ensureCursor() {
    if (zerotier.networks.length === 0) {
      focusSection = "header"
      networkIndex = 0
      return
    }
    if (focusSection !== "networks" && focusSection !== "header") focusSection = "networks"
    if (networkIndex >= zerotier.networks.length) networkIndex = Math.max(0, zerotier.networks.length - 1)
    if (networkIndex < 0) networkIndex = 0
    rememberCursor()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0 && zerotier.networks.length > 0) {
        focusSection = "networks"
        networkIndex = 0
      }
      return
    }
    if (focusSection === "networks") {
      if (dy < 0 && networkIndex === 0) {
        setHeaderCursor()
        return
      }
      networkIndex = Math.max(0, Math.min(zerotier.networks.length - 1, networkIndex + dy))
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setNetworkCursor(index) {
    cursorActive = true
    focusSection = "networks"
    networkIndex = index
    rememberCursor()
  }

  function selectedNetwork() {
    if (zerotier.networks.length === 0) return null
    return zerotier.networks[Math.max(0, Math.min(networkIndex, zerotier.networks.length - 1))]
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") openJoinWindow()
    else if (focusSection === "networks") requestLeave(selectedNetwork())
  }

  function requestLeave(network) {
    if (zerotier.busy || !network) return
    pendingLeave = network
  }

  // Leaving a network is the only destructive action this widget exposes, and
  // a controller-supplied name is not a trustworthy label to hang it on:
  // Unicode confusables and zero-width characters can make one network's name
  // render identically to another's, and unlike the bidi controls that
  // Service.plain() drops, no string sanitising fixes that in general —
  // banning non-Latin scripts is not an option.
  //
  // The nwid is formatted by the local zerotier-one daemon rather than being
  // free-form controller text, so it is the one identifier on this surface a
  // controller cannot forge. Showing it next to the name anchors the decision
  // to something unspoofable. The name is length-bounded so it can never wrap
  // the nwid off the bottom of ConfirmDialog's card.
  function leaveMessage(network) {
    if (!network) return ""
    var nwid = String(network.nwid || "")
    var name = String(network.name || "")
    if (name.length > 40) name = name.substring(0, 39) + "…"
    return name === ""
      ? "Leave network " + nwid + "?"
      : "Leave network " + name + " (" + nwid + ")?"
  }

  function openJoinWindow() {
    joinField.openWith("")
    joinWindowOpen = true
  }

  function cancelJoin() {
    joinWindowOpen = false
    joinField.dismiss()
    keyCatcher.forceActiveFocus()
  }

  function confirmJoin() {
    if (!joinAccepted) return
    var nwid = joinNwid
    cancelJoin()
    zerotier.join(nwid)
  }

  function openInfo(network) {
    if (!network) return
    infoNetwork = network
  }

  function closeInfo() {
    infoNetwork = null
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "" || text === "--") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    pendingLeave = null
    cancelJoin()
    if (opened) {
      closeInfo()
      cursorActive = false
      zerotier.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onNetworkIndexChanged: rememberCursor()

  Service {
    id: zerotier
    settings: root.settings
  }

  Connections {
    target: zerotier
    function onNetworksChanged() { root.restoreCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): string {
      return zerotier.refresh() ? "ok" : "error: " + zerotier.actionRejection
    }
    function status(): string {
      return zerotier.networks.length + " network(s) joined"
    }
    function join(nwid: string): string {
      return zerotier.join(nwid) ? "ok" : "error: " + zerotier.actionRejection
    }
    function leave(nwid: string): string {
      var network = zerotier.findByNwid(nwid)
      if (!network) return "error: not a member of " + nwid
      return zerotier.leave(network) ? "ok" : "error: " + zerotier.actionRejection
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        implicitWidth: Style.bar.iconCanvas
        implicitHeight: Style.bar.iconCanvas

        Image {
          id: barLogoImage
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/zerotier-logo.png")
          sourceSize.width: Style.bar.iconCanvas * Screen.devicePixelRatio
          sourceSize.height: Style.bar.iconCanvas * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: barLogoImage
          source: barLogoImage
          colorization: 1.0
          colorizationColor: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) zerotier.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pendingLeave !== null || root.joinWindowOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") zerotier.refresh()
        else if (t === "n" || t === "N") root.openJoinWindow()
        else if (t === "l" || t === "L") {
          if (root.cursorActive && root.focusSection === "networks") root.requestLeave(root.selectedNetwork())
        } else if (t === "i" || t === "I") {
          if (root.cursorActive && root.focusSection === "networks") root.openInfo(root.selectedNetwork())
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onEntered: root.cursorActive = false
      }

      HoverHandler {
        onHoveredChanged: if (!hovered) root.cursorActive = false
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Omanodes"
              meta: zerotier.networks.length + " network" + (zerotier.networks.length === 1 ? "" : "s")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Item {
                  implicitWidth: Style.font.display
                  implicitHeight: Style.font.display

                  Image {
                    id: heroLogoImage
                    anchors.fill: parent
                    source: Qt.resolvedUrl("assets/zerotier-logo.png")
                    sourceSize.width: Style.font.display * Screen.devicePixelRatio
                    sourceSize.height: Style.font.display * Screen.devicePixelRatio
                    fillMode: Image.PreserveAspectFit
                    visible: false
                    layer.enabled: true
                  }

                  MultiEffect {
                    anchors.fill: heroLogoImage
                    source: heroLogoImage
                    colorization: 1.0
                    colorizationColor: root.iconColor
                  }
                }
              }

              trailingControl: Component {
                Row {
                  spacing: Style.space(4)

                  PanelActionButton {
                    iconText: "󰐕"
                    tooltipText: "Join a network by ID (n)"
                    anchors.verticalCenter: parent.verticalCenter
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    enabled: !zerotier.busy
                    onHovered: function(on) { if (on) header.focusHero() }
                    onClicked: root.openJoinWindow()
                  }
                }
              }
            }
          }

          Text {
            visible: zerotier.actionStatus !== "" || zerotier.lastError !== ""
            width: parent.width
            text: zerotier.actionStatus !== "" ? zerotier.actionStatus : zerotier.lastError
            textFormat: Text.PlainText
            color: zerotier.lastError !== "" && zerotier.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "NETWORKS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: zerotier.networks.length === 0
              width: parent.width
              text: "No ZeroTier networks joined\nJoin one with the + button or n"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WrapAnywhere
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: networkColumn
              visible: zerotier.networks.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: networkRepeater
                model: zerotier.networks
                NetworkRow {
                  required property var modelData
                  required property int index
                  width: networkColumn.width
                  network: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: leaveDialog
        anchors.fill: parent
        opened: root.pendingLeave !== null
        // ConfirmDialog is a shared qs.Ui component and renders its message
        // with QML's default AutoText, so the network name inside this string
        // is safe only because Service.plain() already neutralised it on the
        // way into the model. See leaveMessage() for why the nwid is in here.
        message: root.leaveMessage(root.pendingLeave)
        confirmText: "Leave"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Keys.onPressed: function(event) { event.accepted = leaveDialog.handleKey(event) }
        onOpenedChanged: {
          if (opened) {
            selectedIndex = 0
            forceActiveFocus()
          } else {
            keyCatcher.forceActiveFocus()
          }
        }
        onCanceled: root.pendingLeave = null
        onConfirmed: {
          var network = root.pendingLeave
          root.pendingLeave = null
          zerotier.leave(network)
        }
      }
    }
  }

  JoinNetworkWindow {
    id: joinWindow
    anchorItem: button
    open: root.joinWindowOpen
    accepted: root.joinAccepted
    hint: root.joinHintText
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onConfirmed: root.confirmJoin()
    onCanceled: root.cancelJoin()
  }

  NetworkStatusWindow {
    id: statusWindow
    anchorItem: button
    open: root.infoNetwork !== null
    network: root.infoNetwork
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onCloseRequested: root.closeInfo()
    onCopyRequested: function(value) { root.copyToClipboard(value) }
  }

  // JoinNetworkWindow exposes its embedded NamePrompt as `field` so the
  // header's join accessors (joinNwid/openJoinWindow/cancelJoin) can drive
  // value/openWith/dismiss without reaching into the window's internals.
  property alias joinField: joinWindow.field

  component NetworkRow: CursorSurface {
    id: networkRow
    property var network: null
    property int rowIndex: 0
    readonly property bool joined: network ? network.status === "OK" : false

    hasCursor: root.cursorActive && root.focusSection === "networks" && root.networkIndex === rowIndex
    current: joined
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onEntered: root.setNetworkCursor(networkRow.rowIndex)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: networkRow.joined ? "󰄬" : "󰅙"
        textFormat: Text.PlainText
        color: networkRow.joined ? root.foreground : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: networkRow.network ? (networkRow.network.name || networkRow.network.nwid) : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (!networkRow.network) return ""
            var parts = [networkRow.network.nwid]
            if (networkRow.network.assignedIp !== "") parts.push(networkRow.network.assignedIp)
            else parts.push(networkRow.network.status)
            return parts.join(" · ")
          }
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: networkRow.joined ? "󰈂" : "󰈀"
        tooltipText: networkRow.joined ? "Leave network (l)" : "Join network"
        foreground: root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !zerotier.busy
        visible: networkRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestLeave(networkRow.network)
      }

      PanelActionButton {
        iconText: "󰋼"
        tooltipText: "Network info (i)"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        visible: networkRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openInfo(networkRow.network)
      }
    }
  }
}
