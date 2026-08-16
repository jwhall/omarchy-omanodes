import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The "join a network" prompt as a screen-centred window, same reasoning as
// Omawire's RenameWindow: the bar popup is a narrow column pinned under its
// icon, too cramped for a comfortable text field. Frame copied from
// RenameWindow.qml; only the namespace, title/placeholder and the `field`
// alias (so Panel.qml can read the typed value for validation) differ.
PanelWindow {
  id: root

  required property Item anchorItem
  property bool open: false
  property bool accepted: false
  property string hint: ""
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // Exposes the embedded NamePrompt so the panel can read `value` and call
  // `openWith`/`dismiss` for the header's + button and the `n` shortcut.
  property alias field: prompt

  signal confirmed()
  signal canceled()

  visible: open
  screen: anchorItem && anchorItem.QsWindow.window ? anchorItem.QsWindow.window.screen : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "jwhall-omanodes-join"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  onOpenChanged: {
    if (open) Qt.callLater(function() {
      if (root.open) prompt.focusField()
    })
  }

  NamePrompt {
    id: prompt
    anchors.fill: parent
    title: "Join Network"
    placeholder: "16-character hex ID"
    hint: root.hint
    accepted: root.accepted
    confirmLabel: "Join"
    maxCardWidth: Style.space(420)
    foreground: root.foreground
    dim: root.dim
    urgent: root.urgent
    fontFamily: root.fontFamily
    onConfirmed: root.confirmed()
    onCanceled: root.canceled()
  }
}
