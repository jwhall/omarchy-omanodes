import QtQuick
import Quickshell
import Quickshell.Io

// Headless state for the ZeroTier widget: lists networks known to the local
// zerotier-one service and joins/leaves them through backend.sh.
//
// zerotier-cli's local API is authorized by a root-only token file, so
// unlike Omawire's nmcli backend, *every* call here — including the status
// poll — runs through backend.sh's require_root/pkexec self-elevation, not
// just joins/leaves.
Item {
  id: root

  property var settings: ({})

  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  // {nwid, name, status, type, mac, assignedIp, portDeviceName} — parsed
  // straight from `zerotier-cli -j listnetworks`, sorted by name.
  property var networks: []
  property string actionStatus: ""
  property string lastError: ""
  // Public action methods return true only after they actually started
  // work; actionRejection carries the reason otherwise.
  property string actionRejection: ""

  readonly property bool busy: controlProcess.running
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function rejectAction(reason) {
    actionRejection = String(reason)
    lastError = actionRejection
    return false
  }

  function refresh() {
    if (statusProcess.running) {
      actionRejection = "a refresh is already running"
      return false
    }
    actionRejection = ""
    statusProcess.running = true
    return true
  }

  function refreshAfterChange() {
    if (statusProcess.running) {
      _refreshAfterStatus = true
      return false
    }
    return refresh()
  }

  function findByNwid(nwid) {
    var value = String(nwid || "")
    for (var i = 0; i < networks.length; i++) {
      if (networks[i].nwid === value) return networks[i]
    }
    return null
  }

  function isValidNwid(nwid) {
    return /^[0-9a-fA-F]{16}$/.test(String(nwid || ""))
  }

  function applyStatus(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || "[]"))
    } catch (e) {
      lastError = "Failed to parse ZeroTier status"
      _pollError = true
      return
    }
    if (!Array.isArray(parsed)) {
      lastError = "Failed to read ZeroTier status"
      _pollError = true
      return
    }
    var list = []
    for (var i = 0; i < parsed.length; i++) {
      var n = parsed[i]
      if (!n || !n.id) continue
      var addrs = Array.isArray(n.assignedAddresses) ? n.assignedAddresses : []
      list.push({
        nwid: String(n.id),
        name: String(n.name || ""),
        status: String(n.status || ""),
        type: String(n.type || ""),
        mac: String(n.mac || ""),
        portDeviceName: String(n.portDeviceName || ""),
        assignedIp: addrs.length > 0 ? String(addrs[0]) : "",
        assignedIps: addrs.map(function(a) { return String(a) })
      })
    }
    list.sort(function(a, b) {
      var an = a.name || a.nwid
      var bn = b.name || b.nwid
      return an < bn ? -1 : (an > bn ? 1 : 0)
    })
    networks = list
    if (_pollError) {
      _pollError = false
      lastError = ""
    }
  }

  function join(nwid) {
    if (busy) return rejectAction("another ZeroTier operation is already running")
    var value = String(nwid || "")
    if (!isValidNwid(value)) return rejectAction("invalid network ID")
    actionRejection = ""
    actionStatus = "Joining " + value + "…"
    runControl(["join", value])
    return true
  }

  function leave(network) {
    if (busy) return rejectAction("another ZeroTier operation is already running")
    if (!network || !network.nwid) return rejectAction("no such network")
    actionRejection = ""
    actionStatus = "Leaving " + (network.name || network.nwid) + "…"
    runControl(["leave", network.nwid])
    return true
  }

  function runControl(args) {
    _controlError = ""
    _controlOperation = String(args[0])
    controlProcess.command = ["bash", backendPath].concat(args)
    controlProcess.running = true
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  property string _controlError: ""
  property string _controlOperation: ""
  property bool _pollError: false
  property bool _refreshAfterStatus: false

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: ["bash", root.backendPath, "status"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyStatus(statusStdout.text)
      } else {
        root.lastError = root.elide(statusStderr.text || "Failed to read ZeroTier status")
        root._pollError = true
      }
      if (root._refreshAfterStatus) {
        root._refreshAfterStatus = false
        Qt.callLater(root.refreshAfterChange)
      }
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    onExited: function(exitCode) {
      root._controlOperation = ""
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        root.lastError = root.elide(root._controlError || "ZeroTier operation failed")
      }
      root.actionStatus = ""
      root.refreshAfterChange()
    }
  }
}
