import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget (kind: "bar-widget"). A thin GUI over bin/sudo-watchctl: every
// control shells out to the CLI with an argv array (never a shell string) and
// only ever passes integers or on/off from bounded controls, so the CLI stays
// the single place that validates and writes the config.
BarWidget {
  id: root
  moduleName: "taylorburke.sudo-watch"

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string ctl: pluginDir + "bin/sudo-watchctl"

  property bool popupOpen: false
  function close() { popupOpen = false }

  // Mirrors of `sudo-watchctl status`; refreshed on open and after each change.
  property bool serviceActive: false
  property string serviceText: "unknown"
  property int volume: 100
  property bool escalate: false
  property int volumeStep: 10
  property int volumeMax: 150
  property int threshold: 20
  property int repeatEvery: 10
  property int maxAlerts: 10   // 0 = unlimited

  implicitWidth: glyph.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function parseStatus(text) {
    var m
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if ((m = line.match(/^Volume:\s+(\d+)%/))) volume = parseInt(m[1])
      else if ((m = line.match(/^Escalate:\s+(on|off)/))) {
        escalate = m[1] === "on"
        var s = line.match(/\+(\d+)% per repeat, cap (\d+)%/)
        if (s) { volumeStep = parseInt(s[1]); volumeMax = parseInt(s[2]) }
      }
      else if ((m = line.match(/^Threshold:\s+(\d+)s/))) threshold = parseInt(m[1])
      else if ((m = line.match(/^Repeat every:\s+(\d+)s/))) repeatEvery = parseInt(m[1])
      else if ((m = line.match(/^Max alerts:\s+(\d+|unlimited)/))) maxAlerts = m[1] === "unlimited" ? 0 : parseInt(m[1])
      else if ((m = line.match(/^Service:\s+(.*)$/))) {
        serviceText = m[1].trim()
        serviceActive = serviceText.indexOf("active") === 0
      }
    }
  }

  function refresh() { statusProc.running = true }

  // Queue of argv arrays so rapid slider/field changes never race one Process.
  property var pending: []
  function run(args) {
    pending.push([ctl].concat(args))
    if (!actionProc.running) next()
  }
  function next() {
    if (pending.length === 0) return
    actionProc.command = pending.shift()
    actionProc.running = true
  }

  Process {
    id: statusProc
    command: [root.ctl, "status"]
    stdout: StdioCollector { onStreamFinished: root.parseStatus(text) }
  }

  Process {
    id: actionProc
    onExited: { root.refresh(); root.next() }
  }

  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "󰌾"
    color: root.serviceActive ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.8)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.body
    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  readonly property bool tooltipHovered: mouseArea.containsMouse

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.popupOpen = !root.popupOpen; if (root.popupOpen) root.refresh() }
    onEntered: if (root.bar) root.bar.showTooltip(root, "Sudo Watch: " + root.serviceText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "Sudo Watch"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.serviceText
          color: root.serviceActive ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Text {
        textFormat: Text.PlainText
        text: "Volume  " + root.volume + "%"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      PanelSlider {
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: 200
        step: 5
        integer: true
        value: root.volume
        onReleased: function(v) { root.volume = Math.round(v); root.run(["volume", String(Math.round(v))]) }
      }

      Toggle {
        width: parent.width
        label: "Escalate on repeat"
        description: "Ramp volume up on each repeat alert"
        checked: root.escalate
        foreground: root.bar.foreground
        onClicked: { root.escalate = !root.escalate; root.run(["escalate", root.escalate ? "on" : "off"]) }
      }

      // Two settings per row, each in a half-width cell, so the popup stays
      // compact instead of leaving the right half of every row empty.
      Row {
        visible: root.escalate
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: (parent.width - parent.spacing) / 2
          height: stepField.implicitHeight
          NumberField {
            id: stepField
            label: "Step %"
            from: 0
            to: 100
            value: root.volumeStep
            foreground: root.bar.foreground
            onModified: function(v) { root.volumeStep = v; root.run(["volume-step", String(v)]) }
          }
        }
        Item {
          width: (parent.width - parent.spacing) / 2
          height: capField.implicitHeight
          NumberField {
            id: capField
            label: "Cap %"
            from: 0
            to: 500
            value: root.volumeMax
            foreground: root.bar.foreground
            onModified: function(v) { root.volumeMax = v; root.run(["volume-max", String(v)]) }
          }
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: (parent.width - parent.spacing) / 2
          height: thresholdField.implicitHeight
          NumberField {
            id: thresholdField
            label: "First (s)"
            from: 1
            to: 3600
            value: root.threshold
            foreground: root.bar.foreground
            onModified: function(v) { root.threshold = v; root.run(["threshold", String(v)]) }
          }
        }
        Item {
          width: (parent.width - parent.spacing) / 2
          height: repeatField.implicitHeight
          NumberField {
            id: repeatField
            label: "Repeat (s)"
            from: 1
            to: 3600
            value: root.repeatEvery
            foreground: root.bar.foreground
            onModified: function(v) { root.repeatEvery = v; root.run(["repeat", String(v)]) }
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: (parent.width - parent.spacing) / 2
          height: Math.max(maxAlertsField.implicitHeight, testButton.implicitHeight)
          NumberField {
            id: maxAlertsField
            anchors.verticalCenter: parent.verticalCenter
            label: "Max alerts"
            from: 0
            to: 1000
            value: root.maxAlerts
            foreground: root.bar.foreground
            onModified: function(v) { root.maxAlerts = v; root.run(["max-alerts", v === 0 ? "unlimited" : String(v)]) }
          }
        }
        Item {
          width: (parent.width - parent.spacing) / 2
          height: Math.max(maxAlertsField.implicitHeight, testButton.implicitHeight)
          Button {
            id: testButton
            anchors.centerIn: parent
            iconText: "󰕾"
            text: "Test sound"
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.run(["test"])
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.maxAlerts === 0
        text: "Max alerts 0 = unlimited"
        color: Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
