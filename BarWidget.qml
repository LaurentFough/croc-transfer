import QtQuick
import qs.Commons
import qs.Ui

// The drop target: files dropped on the bar icon start a send immediately.
// Click opens the card. The label tracks the transfer: idle icon, ··· while
// waiting for the recipient, live percentage while bytes move.
BarWidget {
  id: root
  moduleName: "io.github.alexdont.croc-transfer"

  // Resolved lazily and re-tried: at shell startup the widget can be built
  // before the service registers (same defense as the other plugins).
  property var svc: null

  function resolveSvc() {
    if (!svc && bar && bar.shell) svc = bar.shell.serviceFor(moduleName)
    return svc
  }

  onBarChanged: resolveSvc()
  Component.onCompleted: resolveSvc()

  Timer {
    interval: 400
    repeat: true
    running: !root.svc
    onTriggered: root.resolveSvc()
  }

  // Services never see shell.json settings; the widget owns the schema
  // entry and pushes the relay into the service. Validated there before use.
  Binding {
    target: root.svc
    property: "relay"
    value: String(root.setting("relay", ""))
    when: !!root.svc
  }

  // file:// URLs from a drag, decoded and filtered to absolute local paths.
  function dropPaths(drop) {
    var raw = []
    if (drop.hasUrls) for (var j = 0; j < drop.urls.length; j++) raw.push(String(drop.urls[j]))
    else if (drop.hasText) raw = String(drop.text).split("\n")
    var out = []
    for (var k = 0; k < raw.length && out.length < 32; k++) {
      var p = raw[k].trim().replace(/^file:\/\//, "")
      try { p = decodeURIComponent(p) } catch (e) { continue }
      if (p.charAt(0) === "/") out.push(p)
    }
    return out
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var s = root.svc
      if (!s || s.phase === "idle") return "󰒊"
      if (s.phase === "waiting") return "󰒊 ···"
      if (s.progressPct >= 0) return "󰒊 " + s.progressPct + "%"
      return "󰒊 ···"
    }
    horizontalMargin: 7.5
    onPressed: function(b) {
      var s = root.resolveSvc()
      if (s) s.toggleOverlay()
    }
  }

  DropArea {
    anchors.fill: parent
    onDropped: function(drop) {
      var s = root.resolveSvc()
      if (!s) return
      var paths = root.dropPaths(drop)
      if (paths.length > 0) s.send(paths)
    }
  }
}
