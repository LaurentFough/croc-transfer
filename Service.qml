import QtQuick
import Quickshell
import Quickshell.Io

// Headless singleton that owns the transfer lifecycle. One transfer at a
// time: send (drop/IPC) or receive (pasted code). croc does the crypto and
// the relay protocol; this service babysits the process, captures the code
// phrase, and parses progress. Deliberately no state file — a transfer's
// only record is its notification.
//
// Two hard-won croc facts (verified against croc 11.1.0):
// - croc prioritizes piped stdin over file arguments, so every launch
//   redirects < /dev/null or a drop would silently send 0 bytes of stdin.
// - Everything (code phrase, progress) is printed to stderr, with \r
//   separating progress redraws — hence 2>&1 and the chunk parser below.
Item {
  id: root

  property var shell: null
  property var settings: ({})

  readonly property string pluginId: "io.github.alexdont.croc-transfer"
  readonly property string downloadDir: Quickshell.env("HOME") + "/Downloads"

  property bool crocInstalled: false
  // idle | starting | waiting | transferring | receiving
  property string phase: "idle"
  property string code: ""
  property string fileLabel: ""
  property int progressPct: -1
  property string speed: ""
  property string lastError: ""
  property bool cancelled: false

  // Custom relay, bound in by the bar widget from its schema settings
  // (services don't receive shell.json settings directly). Validated here
  // before use regardless of where the value came from.
  property string relay: ""

  readonly property bool busy: phase !== "idle"

  function validRelay(r) {
    return /^[A-Za-z0-9.\[\]:-]{1,128}$/.test(r)
  }

  // croc codes are dash-joined words/digits. First char alphanumeric so a
  // pasted value can never be parsed as a flag.
  function validCode(c) {
    return /^[A-Za-z0-9][A-Za-z0-9-]{2,63}$/.test(c)
  }

  function validPath(p) {
    return typeof p === "string" && p.length > 0 && p.length <= 4096
      && p.charAt(0) === "/" && p.indexOf("\n") === -1
  }

  function probeDeps() { if (!depsProbe.running) depsProbe.running = true }

  // ---- send ---------------------------------------------------------------

  function rejectBusy() {
    Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
      "Croc Transfer", "A transfer is already running — cancel it first"])
  }

  // paths: array of absolute file/dir paths (croc handles dirs natively).
  function send(paths) {
    if (!Array.isArray(paths) || paths.length === 0) return
    if (root.busy) { root.rejectBusy(); return }
    var clean = []
    for (var j = 0; j < paths.length && clean.length < 32; j++)
      if (root.validPath(paths[j])) clean.push(paths[j])
    if (clean.length === 0) return
    if (!root.crocInstalled) {
      root.notifyError("croc is not installed — sudo pacman -S croc")
      root.probeDeps()
      return
    }

    var names = []
    for (var k = 0; k < clean.length; k++) names.push(clean[k].split("/").pop())
    root.fileLabel = names.join(", ").slice(0, 120)
    root.beginTransfer("starting")

    // exec so cancel() signals croc itself, not a wrapper shell; every
    // variable rides in as a positional parameter. --disable-clipboard:
    // croc's own auto-copy would race and clobber the paste-ready
    // "croc <code>" this service puts on the clipboard.
    var relay = root.validRelay(root.relay) ? root.relay : ""
    transferProc.command = ["sh", "-c",
      "relay=\"$1\"; shift; " +
      "if [ -n \"$relay\" ]; then exec croc --disable-clipboard --relay \"$relay\" send \"$@\" < /dev/null 2>&1; " +
      "else exec croc --disable-clipboard send \"$@\" < /dev/null 2>&1; fi",
      "sh", relay].concat(clean)
    transferProc.receiving = false
    transferProc.running = true
  }

  // ---- receive ------------------------------------------------------------

  function receive(codeStr) {
    codeStr = String(codeStr || "").trim()
    if (!root.validCode(codeStr)) return
    if (root.busy) { root.rejectBusy(); return }
    if (!root.crocInstalled) {
      root.notifyError("croc is not installed — sudo pacman -S croc")
      root.probeDeps()
      return
    }
    root.fileLabel = ""
    root.beginTransfer("receiving")

    // The code travels via CROC_SECRET (croc's own recommended form) so it
    // never appears in croc's argv. --yes answers croc's prompts; files
    // land in ~/Downloads.
    var relay = root.validRelay(root.relay) ? root.relay : ""
    transferProc.command = ["sh", "-c",
      "mkdir -p \"$1\" && cd \"$1\" && " +
      "if [ -n \"$3\" ]; then CROC_SECRET=\"$2\" exec croc --relay \"$3\" --yes < /dev/null 2>&1; " +
      "else CROC_SECRET=\"$2\" exec croc --yes < /dev/null 2>&1; fi",
      "sh", root.downloadDir, codeStr, relay]
    transferProc.receiving = true
    transferProc.running = true
    // A wrong code never errors — croc waits at the relay for a sender that
    // will never come. Give up after five minutes unless bytes are flowing.
    receiveGuard.restart()
  }

  // The portal file chooser is a normal window and can never stack above
  // the overlay's layer surface — the card dismisses itself before calling
  // this, and the pick lives here so it survives that dismissal.
  function pickAndSend() {
    if (root.busy || pickProc.running) return
    pickProc.running = true
  }

  function cancel() {
    if (!root.busy) return
    // Busy display without a live process: just clear it.
    if (!transferProc.running) { root.resetIdle(); root.fileLabel = ""; return }
    root.cancelled = true
    transferProc.running = false
  }

  function toggleOverlay() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.pluginId, "{}"])
  }

  // ---- process output parsing --------------------------------------------

  function beginTransfer(phase) {
    root.cancelled = false
    root.code = ""
    root.progressPct = -1
    root.speed = ""
    root.lastError = ""
    root.phase = phase
    parseBuf = ""
  }

  function resetIdle() {
    root.phase = "idle"
    root.code = ""
    root.progressPct = -1
    root.speed = ""
  }

  // croc mixes \n lines (code block) and \r progress redraws in one stream;
  // chunks arrive with no line discipline. Accumulate a small bounded buffer,
  // emit on either terminator.
  property string parseBuf: ""

  function feed(data) {
    var buf = (root.parseBuf + data).slice(-4096)
    var parts = buf.split(/[\r\n]/)
    root.parseBuf = parts.pop()
    for (var j = 0; j < parts.length; j++) root.handleLine(parts[j])
    // Progress redraws sit before a \r that may not have arrived yet —
    // parse the partial tail too, without consuming it.
    if (root.parseBuf.indexOf("%") !== -1) root.handleLine(root.parseBuf)
  }

  function handleLine(line) {
    line = line.slice(0, 512)

    var mCode = line.match(/Code is:\s+(\S+)/)
    if (mCode && root.validCode(mCode[1]) && !root.code) {
      root.code = mCode[1]
      root.phase = "waiting"
      // The paste-ready command is on the clipboard the moment it exists.
      // A tracked Process, not execDetached: wl-copy must inherit the
      // live Wayland environment to take clipboard ownership.
      copyProc.command = ["wl-copy", "croc " + root.code]
      copyProc.running = true
      // -g puts a copy glyph on the toast; --exec makes clicking it re-copy
      // AND open the card — a far bigger target than the bar icon, and the
      // card shows the QR. Embedding the code in the exec string is safe
      // because validCode restricts it to [A-Za-z0-9-].
      Quickshell.execDetached(["omarchy-notification-send",
        "-g", "󰆏", "--exec",
        "wl-copy 'croc " + root.code + "'; omarchy-shell shell summon " + root.pluginId + " '{}'",
        "-u", "low",
        "Croc Transfer", "croc " + root.code + "  — copied · click to open"])
      return
    }

    var mPct = line.match(/(\d{1,3})%\s*\|/)
    if (mPct) {
      var pct = parseInt(mPct[1], 10)
      if (pct >= 0 && pct <= 100) {
        receiveGuard.stop()
        root.progressPct = pct
        if (root.phase === "waiting" || root.phase === "starting") root.phase = "transferring"
        var mSpeed = line.match(/,\s*([0-9.]+\s*[A-Za-z]+\/s)\)/)
        root.speed = mSpeed ? mSpeed[1] : root.speed
      }
      return
    }

    if (/(error|failed|refused|cannot|bad password)/i.test(line) && !root.lastError)
      root.lastError = line.slice(0, 160)
  }

  function notifyError(msg) {
    Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
      "Croc Transfer", msg.slice(0, 200)])
  }

  Component.onCompleted: probeDeps()

  Process { id: copyProc }

  Process {
    id: pickProc
    command: ["sh", "-c", "{ omarchy-file-select --multiple --title 'Send with croc' 2>/dev/null || true; } | head -c 8192"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = text.split("\n")
        var out = []
        for (var j = 0; j < lines.length && out.length < 32; j++) {
          var p = lines[j].trim()
          if (p.charAt(0) === "/") out.push(p)
        }
        if (out.length > 0) root.send(out)
      }
    }
  }

  Timer {
    id: receiveGuard
    interval: 300000
    onTriggered: {
      if (root.phase !== "receiving") return
      root.cancelled = true
      transferProc.running = false
      root.notifyError("No sender found for that code — gave up after 5 minutes")
    }
  }

  Process {
    id: depsProbe
    command: ["sh", "-c", "{ command -v croc || true; } | head -c 256"]
    stdout: StdioCollector {
      onStreamFinished: root.crocInstalled = text.trim().length > 0
    }
  }

  Process {
    id: transferProc
    property bool receiving: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.feed(data) }
    }
    onExited: function(exitCode, exitStatus) {
      receiveGuard.stop()
      var wasReceiving = transferProc.receiving
      var hadProgress = root.progressPct >= 0
      var cancelled = root.cancelled
      var err = root.lastError
      root.resetIdle()
      if (cancelled) return
      if (exitCode === 0 && (hadProgress || wasReceiving)) {
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
          "Croc Transfer", wasReceiving
            ? "Received — saved in ~/Downloads"
            : "Sent ✓ " + root.fileLabel])
      } else if (exitCode !== 0) {
        root.notifyError(err || ((wasReceiving ? "Receive" : "Send") + " failed (exit " + exitCode + ")"))
      }
    }
  }

  // Scripting/keybindings: omarchy-shell croctransfer send /path/to/file
  IpcHandler {
    target: "croctransfer"
    function toggle(): void { root.toggleOverlay() }
    function pick(): void { root.pickAndSend() }
    function send(path: string): void { root.send([path]) }
    function receive(code: string): void { root.receive(code) }
    function cancel(): void { root.cancel() }
    function status(): string {
      return JSON.stringify({
        crocInstalled: root.crocInstalled, phase: root.phase, code: root.code,
        file: root.fileLabel, progressPct: root.progressPct, speed: root.speed,
        lastError: root.lastError
      })
    }
  }
}
