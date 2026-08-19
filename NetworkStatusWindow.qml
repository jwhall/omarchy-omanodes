import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Network detail window, screen-centred like Omawire's QrWindow — the panel
// closes as this opens, and this surface is where any per-network detail
// worth reading in full (a long assigned-address list) gets room to show.
//
// Local-only: zerotier-cli on a member/leaf node cannot list a network's
// other members or their assigned addresses (that lives on the network
// controller, a separate API this widget does not talk to) — so unlike a
// VPN peer list, this window shows only what this host itself knows about
// its own membership.
PanelWindow {
  id: root

  required property Item anchorItem
  property bool open: false
  property var network: null
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal closeRequested()
  signal copyRequested(string value)

  readonly property string title: network ? (network.name || network.nwid || "") : ""

  visible: open
  screen: anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "jwhall-omanodes-status"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  onOpenChanged: {
    if (open) Qt.callLater(function() {
      if (root.open) keyCatcher.forceActiveFocus()
    })
  }

  function text(value) {
    var v = String(value || "")
    return v === "" ? "--" : v
  }

  // Label left (fixed width, dim), value right-aligned and elided with a
  // full-text tooltip and click-to-copy for identifiers worth pasting
  // elsewhere — same shape as Omawire's DetailPair.
  component DetailRow: Item {
    id: pairRow
    property string label: ""
    property string value: ""
    property bool copyable: false
    width: parent ? parent.width : 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    Text {
      id: pairLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(90)
      text: pairRow.label
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: pairValue
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: pairRow.value
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle

      MouseArea {
        anchors.fill: parent
        enabled: pairRow.copyable
        hoverEnabled: enabled
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copyRequested(pairRow.value)
      }

      // Same as ConfirmDialog in Panel.qml: PanelToolTip lives in the shared
      // qs.Ui library and renders AutoText, so this value is safe only
      // because Service.plain() neutralised it at the model boundary.
      PanelToolTip {
        visible: pairRow.copyable && parent.truncated
        text: pairRow.value
        fontFamily: root.fontFamily
      }
    }
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_I
          || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.closeRequested()
        event.accepted = true
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)

      MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }
    }

    BorderSurface {
      id: card
      width: Math.min((anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen.width : 800) - Style.space(64), Style.space(360))
      height: card.contentTopInset + card.contentBottomInset + content.implicitHeight
      anchors.centerIn: parent
      color: Color.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: root.title
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideMiddle
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          DetailRow { label: "Name"; value: root.text(root.network ? root.network.name : "") }
          DetailRow { label: "Network ID"; value: root.text(root.network ? root.network.nwid : ""); copyable: true }
          DetailRow { label: "Type"; value: root.text(root.network ? root.network.type : "") }
          DetailRow { label: "Status"; value: root.text(root.network ? root.network.status : "") }
          DetailRow {
            label: "Assigned IP"
            value: root.text(root.network && root.network.assignedIps && root.network.assignedIps.length > 0
              ? root.network.assignedIps.join(", ") : "")
            copyable: root.network ? root.network.assignedIp !== "" : false
          }
          DetailRow { label: "MAC"; value: root.text(root.network ? root.network.mac : "") }
          DetailRow { label: "Interface"; value: root.text(root.network ? root.network.portDeviceName : "") }
        }
      }
    }
  }
}
