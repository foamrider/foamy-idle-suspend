// foamy-kit 0.15.1 1fc4248ee077efd167203fbef50fa23a2978d6336c490a3a8f8324ac9a979639 — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io

// A StdioCollector with a memory bound, for a Process's stdout or stderr.
// StdioCollector keeps the whole stream, however much the child prints; only
// the process's deadline bounds it (REVIEW.md section 5). This one keeps the
// start of the stream, at most `limit` characters, drops the rest as it
// arrives, and says so (`truncated`).
//
//   Process {
//     id: probe
//     command: ["timeout", "--kill-after=1s", "5s", "hostnamectl", "chassis"]
//     stdout: FoamyBoundedCollector { id: probeOut }               // 65536 characters
//     stderr: FoamyBoundedCollector { id: probeError; limit: 4096 }
//     onStarted: { probeOut.clear(); probeError.clear() }
//     onExited: function (code) {
//       if (probeOut.truncated) root.fail("hostnamectl printed more than expected")
//       else root.read(probeOut.text, probeError.text)
//     }
//   }
//
// - `text` is the kept start of the stream. Read it in the Process's
//   `exited` handler: the whole output has arrived by then.
// - `truncated`: the stream was longer than `limit`, so `text` is only its
//   start. Never parse such output as a whole reply; an error message may
//   use its start. After the cut the collector keeps nothing more until
//   clear(), so `text` is always the start of the stream.
// - clear() starts a new stream: call it in the Process's `started`
//   handler (before any output arrives). Without it a run adds to the last
//   run's text, as no other signal tells the collector a run began.
// - `limit` counts UTF-16 units, as `text.length` does; the cut never keeps
//   half of a surrogate pair, so the text can end one unit short of
//   `limit`. Changing `limit` applies to the output still to come.
// - Quickshell decodes each read of the pipe on its own, so a character
//   whose UTF-8 bytes arrive in two reads shows as U+FFFD at the edge
//   (StdioCollector decodes the whole stream at once). Output that arrives
//   in one read, or ASCII, is exact: a system tool's status or error line.
SplitParser {
  id: root

  property int limit: 65536
  readonly property string text: _text
  readonly property bool truncated: _truncated
  property string _text: ""
  property bool _truncated: false

  function clear() {
    _text = ""
    _truncated = false
  }

  // Chunks as they arrive (no split marker), so nothing waits for a line
  // end in Quickshell's buffer and only `limit` characters are ever kept.
  splitMarker: ""
  onRead: function (data) {
    // After a cut, later output is dropped too, even where the cut left
    // room (it backs off a surrogate pair): `text` stays the stream's start.
    if (_truncated)
      return
    var room = Math.max(0, limit) - _text.length
    if (data.length <= room) {
      _text += data
      return
    }
    _truncated = true
    if (room <= 0)
      return
    var cut = room
    var code = data.charCodeAt(cut - 1)
    if (code >= 0xD800 && code < 0xDC00)
      cut--
    _text += data.slice(0, cut)
  }
}
