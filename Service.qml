import QtQuick
import Quickshell.Io

// Omarchy plugin entry point (kind: "service"). Thin wrapper: all of the
// actual polling/alerting logic lives in bin/sudo-watch.sh (also used by
// the standalone systemd install path in install.sh); this just launches
// it as a supervised child process for the lifetime of the plugin.
Item {
  id: root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string scriptPath: pluginDir + "bin/sudo-watch.sh"

  Process {
    id: watcher
    command: [root.scriptPath]
    running: true

    onExited: function(exitCode, exitStatus) {
      console.warn("sudo-watch: watcher exited unexpectedly (code " + exitCode + ", status " + exitStatus + "); restarting in 5s")
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: watcher.running = true
  }

  Component.onCompleted: console.log("sudo-watch: service loaded, watching for sudo/pkexec prompts")
}
