import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import Qt.labs.settings
import qs.Commons
import qs.Ui

// The transfer card. Idle: a drop zone, a file picker, and a receive field.
// Waiting: the code front and center with a scannable QR, since the whole
// point is relaying that code to another human. Moving: progress + cancel.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  readonly property string phase: service ? service.phase : "idle"
  readonly property string code: service ? service.code : ""
  readonly property bool busy: phase !== "idle"

  // QR as a 0/1 module matrix rendered with native rectangles — same
  // approach as the built-in Wi-Fi QR panel, and just as crisp.
  property var qrRows: []
  property int qrSize: 0
  property string qrFor: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)

  // Local settings storage — persistent fallback when service doesn't provide it
  Settings {
    id: appSettings
    property string downloadLocation: "~/Downloads"
  }

  // Download location setting — defaults to ~/Downloads
  property string downloadLocation: root.setting("downloadLocation", "~/Downloads")

  Component.onCompleted: {
    // Initialize download location from persistent storage
    root.downloadLocation = root.setting("downloadLocation", "~/Downloads")
  }

  function setting(key, defaultValue) {
    // Try service first (for host integration)
    if (root.service && typeof root.service.setting === "function") {
      return root.service.setting(key, defaultValue)
    }
    // Fallback to local Qt.labs.settings
    if (key === "downloadLocation") {
      return appSettings.downloadLocation || defaultValue
    }
    return defaultValue
  }

  function setSetting(key, value) {
    // Notify service if it supports setting persistence
    if (root.service && typeof root.service.setSetting === "function") {
      root.service.setSetting(key, value)
    }
    // Always persist locally as fallback
    if (key === "downloadLocation") {
      appSettings.downloadLocation = value
    }
  }

  function open(payloadJson) {
    root.opened = true
    if (root.service) root.service.probeDeps()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.alexdont.croc-transfer")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

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

  property bool codeCopied: false
  Timer { id: copiedReset; interval: 1400; onTriggered: root.codeCopied = false }

  function copyCode() {
    if (!root.code) return
    Quickshell.execDetached(["wl-copy", "croc " + root.code])
    root.codeCopied = true
    copiedReset.restart()
  }

  function submitReceive() {
    var c = receiveInput.text.trim().replace(/^croc\s+/, "")
    if (root.service && c) {
      root.service.receive(c)
      receiveInput.text = ""
    }
  }

  function expandPath(path) {
    // Simple tilde expansion
    if (path.indexOf("~") === 0) {
      return path.replace(/^~/, Quickshell.env("HOME") || "/root")
    }
    return path
  }

  function browseDownloadLocation() {
    // Try service first (for host integration)
    if (root.service && typeof root.service.pickDirectory === "function") {
      root.service.pickDirectory(function(selectedPath) {
        if (selectedPath) {
          root.downloadLocation = selectedPath
          root.setSetting("downloadLocation", selectedPath)
          downloadPathInput.text = selectedPath
        }
      })
    } else {
      // Fallback: use system file dialog (kdialog for KDE, zenity for GNOME)
      var expandedPath = root.expandPath(root.downloadLocation)
      var cmd = [
        "bash", "-c",
        "kdialog --getexistingdirectory \"" + expandedPath + "\" 2>/dev/null || zenity --file-selection --directory --filename=\"" + expandedPath + "\" 2>/dev/null"
      ]
      var proc = Quickshell.exec(cmd)
      proc.onFinished.connect(function(code) {
        if (code === 0) {
          var path = String(proc.stdout).trim()
          if (path && path.length > 0) {
            root.downloadLocation = path
            root.setSetting("downloadLocation", path)
            downloadPathInput.text = path
          }
        }
      })
    }
  }

  // QR regenerates when a fresh code appears. qrencode's ASCII output uses
  // two characters per module; the same collapse the built-in network QR
  // does turns it into square 0/1 rows. Margin 4 is the spec quiet zone.
  onCodeChanged: {
    if (!root.code) { root.qrRows = []; root.qrSize = 0; root.qrFor = ""; return }
    if (root.code === root.qrFor || qrProc.running) return
    qrProc.command = ["bash", "-c",
      "{ a=$(printf %s \"$1\" | qrencode --type ASCII --margin 4 --output - 2>/dev/null) || exit 0; " +
      "while IFS= read -r line; do row=; for ((c = 0; c < ${#line}; c += 2)); do " +
      "[[ ${line:c:2} == *#* ]] && row+=1 || row+=0; done; printf '%s\\n' \"$row\"; done <<<\"$a\"; } | head -c 65536",
      "bash", "croc " + root.code]
    qrProc.running = true
  }

  // Accept only a square 0/1 matrix of sane size — anything else renders
  // nothing rather than a code that cannot scan.
  function setQrMatrix(raw) {
    var lines = String(raw || "").trim().split("\n").filter(function(l) { return l !== "" })
    var size = lines.length
    var ok = size >= 21 && size <= 200
    for (var j = 0; ok && j < lines.length; j++)
      if (lines[j].length !== size || !/^[01]+$/.test(lines[j])) ok = false
    root.qrRows = ok ? lines : []
    root.qrSize = ok ? size : 0
    root.qrFor = root.code
  }

  Process {
    id: qrProc
    stdout: StdioCollector {
      onStreamFinished: root.setQrMatrix(text)
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io-github-alexdont-croc-transfer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: content.height + card.contentTopInset + card.contentBottomInset
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      DropArea {
        id: cardDrop
        anchors.fill: parent
        onDropped: function(drop) {
          var paths = root.dropPaths(drop)
          if (root.service && paths.length > 0) root.service.send(paths)
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        visible: cardDrop.containsDrag
        color: "transparent"
        border.width: Style.space(3)
        border.color: root.selectedText
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.dismiss()

        Column {
          id: content
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: card.contentTopInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset
          spacing: Style.spacing.md

          // ---- Header ----
          Item {
            width: parent.width
            height: headerTitle.implicitHeight

            Text {
              id: headerTitle
              anchors.left: parent.left
              text: "Croc Transfer"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.phase === "idle" ? ""
                : root.phase === "waiting" ? "waiting for the other side"
                : root.phase === "starting" ? "starting…"
                : root.phase === "receiving" ? "receiving"
                : "sending"
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            visible: !!root.service && !root.service.crocInstalled
            width: parent.width
            text: "croc is not installed. Install it with:  sudo pacman -S croc"
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // ---- Idle: drop zone + picker ----
          Rectangle {
            visible: !root.busy
            width: parent.width
            height: Style.space(96)
            radius: root.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.border

            Column {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Drop files or a folder anywhere on this card"
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: pickText.implicitWidth + Style.spacing.md * 2
                height: Style.space(26)
                radius: root.cornerRadius / 2
                color: pickHover.containsMouse ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border
                opacity: pickHover.containsMouse ? 1 : 0.7

                Text {
                  id: pickText
                  anchors.centerIn: parent
                  text: "󰈞 Pick files…"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: pickHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  // The chooser can't stack above this layer surface, so the
                  // card gets out of its way; the service owns the pick and
                  // starts the send when the selection lands.
                  onClicked: {
                    var s = root.service
                    root.dismiss()
                    if (s) s.pickAndSend()
                  }
                }
              }
            }
          }

          // ---- Idle: receive ----
          Column {
            visible: !root.busy
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "Receive"
              color: root.selectedText
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Rectangle {
                width: parent.width - receiveBtn.width - Style.spacing.md
                height: Style.space(30)
                radius: root.cornerRadius / 2
                color: root.selectedBackground
                opacity: receiveInput.activeFocus ? 1 : 0.7

                TextInput {
                  id: receiveInput
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  maximumLength: 80
                  onAccepted: root.submitReceive()
                  Keys.onEscapePressed: { receiveInput.text = ""; keyCatcher.forceActiveFocus() }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !receiveInput.text && !receiveInput.activeFocus
                    text: "paste a code someone sent you…"
                    color: root.selectedText
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Rectangle {
                id: receiveBtn
                width: receiveBtnText.implicitWidth + Style.spacing.md * 2
                height: Style.space(30)
                radius: root.cornerRadius / 2
                color: receiveHover.containsMouse ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border
                opacity: receiveInput.text ? 1 : 0.5

                Text {
                  id: receiveBtnText
                  anchors.centerIn: parent
                  text: "Receive"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: receiveHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.submitReceive()
                }
              }
            }

            Text {
              text: "Files land in " + root.downloadLocation + "."
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Idle: download location settings ----
          Column {
            visible: !root.busy
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "Download Location"
              color: root.selectedText
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Rectangle {
                width: parent.width - browseBtn.width - Style.spacing.md
                height: Style.space(30)
                radius: root.cornerRadius / 2
                color: root.selectedBackground
                opacity: downloadPathInput.activeFocus ? 1 : 0.7

                TextInput {
                  id: downloadPathInput
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  text: root.downloadLocation
                  onEditingFinished: {
                    if (downloadPathInput.text) {
                      root.downloadLocation = downloadPathInput.text
                      root.setSetting("downloadLocation", downloadPathInput.text)
                    }
                  }
                  Keys.onEscapePressed: { downloadPathInput.text = root.downloadLocation; keyCatcher.forceActiveFocus() }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !downloadPathInput.text && !downloadPathInput.activeFocus
                    text: "path for received files…"
                    color: root.selectedText
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Rectangle {
                id: browseBtn
                width: browseBtnText.implicitWidth + Style.spacing.md * 2
                height: Style.space(30)
                radius: root.cornerRadius / 2
                color: browseHover.containsMouse ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border

                Text {
                  id: browseBtnText
                  anchors.centerIn: parent
                  text: "󰉋 Browse"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: browseHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.browseDownloadLocation()
                }
              }
            }
          }

          // ---- Active transfer ----
          Column {
            visible: root.busy
            width: parent.width
            spacing: Style.spacing.md

            Text {
              visible: !!(root.service && root.service.fileLabel)
              width: parent.width
              text: root.service ? root.service.fileLabel : ""
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            // The code, front and center — click to copy again.
            Rectangle {
              visible: root.phase === "waiting" && root.code !== ""
              anchors.horizontalCenter: parent.horizontalCenter
              width: codeRow.implicitWidth + Style.spacing.md * 2
              height: Style.space(34)
              radius: root.cornerRadius / 2
              color: root.selectedBackground
              opacity: codeHover.containsMouse ? 1 : 0.85

              Row {
                id: codeRow
                anchors.centerIn: parent
                spacing: Style.spacing.md

                Text {
                  text: "croc " + root.code
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                // The affordance: a copy glyph that flips to a check when
                // the click lands.
                Text {
                  text: root.codeCopied ? "󰄬" : "󰆏"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.selectedText
                  opacity: root.codeCopied || codeHover.containsMouse ? 1 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
              MouseArea {
                id: codeHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyCode()
              }
            }

            Text {
              visible: root.phase === "waiting"
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Copied — paste it to your recipient, they run it in any terminal."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Scannable QR of the same command: every module an integer-sized
            // native rectangle, black on white regardless of theme — a themed
            // QR is a QR that doesn't scan. Only dark modules paint, so the
            // white canvas keeps its rounded corners; the quiet zone baked
            // into the matrix keeps the code clear of them.
            Rectangle {
              id: qrCanvas
              readonly property int moduleSize: root.qrSize > 0
                ? Math.max(3, Math.floor(Style.space(220) / root.qrSize))
                : 0

              visible: root.phase === "waiting" && root.qrSize > 0 && root.qrFor === root.code
              anchors.horizontalCenter: parent.horizontalCenter
              width: root.qrSize * moduleSize
              height: width
              radius: root.cornerRadius / 2
              color: "#ffffff"

              // One Canvas, not per-module Rectangles: at fractional display
              // scale, separate rectangles antialias apart into hairline
              // seams. Painting each dark module a whisker oversized fuses
              // neighbors into solid blocks at any scale.
              Canvas {
                anchors.fill: parent
                property var rows: root.qrRows
                onRowsChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)
                  var n = root.qrSize
                  if (n <= 0 || rows.length !== n) return
                  var m = qrCanvas.moduleSize
                  ctx.fillStyle = "#111111"
                  for (var r = 0; r < n; r++)
                    for (var c = 0; c < n; c++)
                      if (rows[r].charAt(c) === "1") ctx.fillRect(c * m, r * m, m + 0.7, m + 0.7)
                }
              }
            }

            // Progress while bytes move.
            Column {
              visible: root.service && root.service.progressPct >= 0
              width: parent.width
              spacing: Style.space(4)

              Rectangle {
                width: parent.width
                height: Style.space(10)
                radius: height / 2
                color: root.selectedBackground
                opacity: 0.5

                Rectangle {
                  width: Math.max(height, parent.width * (root.service ? root.service.progressPct : 0) / 100)
                  height: parent.height
                  radius: height / 2
                  color: root.selectedText
                  opacity: 0.7
                }
              }

              Text {
                text: (root.service ? root.service.progressPct : 0) + "%"
                  + (root.service && root.service.speed ? "  ·  " + root.service.speed : "")
                textFormat: Text.PlainText
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: cancelText.implicitWidth + Style.spacing.md * 2
              height: Style.space(28)
              radius: root.cornerRadius / 2
              color: cancelHover.containsMouse ? root.selectedBackground : "transparent"
              border.width: 1
              border.color: root.border
              opacity: cancelHover.containsMouse ? 1 : 0.7

              Text {
                id: cancelText
                anchors.centerIn: parent
                text: "Cancel"
                color: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: cancelHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.cancel()
              }
            }
          }

          Text {
            visible: !!(root.service && root.service.lastError) && !root.busy
            width: parent.width
            text: root.service ? root.service.lastError : ""
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "End-to-end encrypted via croc · code is single-use · Esc close"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
