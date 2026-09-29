import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell
  property var manifest

  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string applyScript: pluginDir + "/apply.sh"

  // No FileView on ~/.config/omarchy/touchbar.json (marketplace #6878).
  // FileView follows symlinks and has no size cap, so a FIFO or huge file at
  // that predictable path could stall or exhaust the shell. The layout is
  // applied only when apply.sh runs; apply.sh validates the file first.

  function applyLayout() {
    if (applyProc.running) return
    applyErr.text = ""
    applyProc.running = true
  }

  function reportApplyFailure(exitCode) {
    var detail = String(applyErr.text || "").trim()
    if (!detail) detail = "Could not install the Touch Bar layout (exit " + exitCode + ")"
    Quickshell.execDetached([
      "omarchy-notification-send", "-u", "critical", "-g", "󰁨",
      "Touch Bar", detail
    ])
  }

  Process {
    id: applyProc
    command: ["bash", root.applyScript]
    stdout: StdioCollector { }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reportApplyFailure(exitCode)
    }
  }
}
