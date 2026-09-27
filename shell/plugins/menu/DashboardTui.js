#!/usr/bin/env node
// The dashboard's terminal front end: raw mode, an alternate screen, and a
// redraw loop. Everything it decides lives in shell/plugins/menu/TuiModel.js,
// which has no terminal in it and is tested without one; this file only turns
// keys into model calls and model state into characters.
//
// It shells out to `omarchy menu snapshot` for the tree, rather than reading
// the menu files itself, so the rows it shows come from the same one
// implementation the GTK dashboard renders and the guards were evaluated by.

var path = require("path")
var childProcess = require("child_process")

var TuiModel = require("./TuiModel.js")

var ESC = ""
var CSI = ESC + "["
var RESET = CSI + "0m"
var REVERSE = CSI + "7m"
var DIM = CSI + "2m"
var BOLD = CSI + "1m"
var CLEAR = CSI + "2J"
var HOME = CSI + "H"
var HIDE_CURSOR = CSI + "?25l"
var SHOW_CURSOR = CSI + "?25h"
var ALT_SCREEN_ON = CSI + "?1049h"
var ALT_SCREEN_OFF = CSI + "?1049l"

var KEYS = {
  up: CSI + "A",
  down: CSI + "B",
  right: CSI + "C",
  left: CSI + "D"
}

function omarchyRoot() {
  var root = process.env.OMARCHY_PATH
  if (!root) return path.join(__dirname, "..")
  return root.replace(/\/$/, "")
}

// `omarchy menu snapshot` knows how to find its own Node; asking it to parse
// argv for us would be a second implementation of the same flags, and this
// file is not where a flag should be added.
function parseArgs(argv) {
  var options = { route: "" }

  for (var i = 0; i < argv.length; i++) {
    if (argv[i].indexOf("--route=") === 0) options.route = argv[i].slice("--route=".length)
  }

  return options
}

function loadSnapshot(route) {
  var args = ["menu", "snapshot"]
  if (route) args.push("--route=" + route)

  var output = childProcess.execFileSync("omarchy", args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  })

  return JSON.parse(output)
}

function visibleRows(rows, height) {
  if (rows.length <= height) return rows
  return rows.slice(0, height)
}

// A terminal hands over whatever arrived, not one keystroke. An arrow key is
// three bytes, and Escape followed by q routinely lands in the same read, so
// comparing a whole chunk against a single character loses keys -- and a lost
// "q" is a TUI the user cannot leave. Pull one key off the front of a buffer
// instead, longest sequence first.
var SEQUENCES = [
  CSI + "A", CSI + "B", CSI + "C", CSI + "D",
  CSI + "H", CSI + "F", CSI + "1~", CSI + "3~", CSI + "4~"
]

function decodeKey(buffer) {
  if (buffer.length === 0) return null

  for (var i = 0; i < SEQUENCES.length; i++) {
    if (buffer.indexOf(SEQUENCES[i]) === 0) return { key: SEQUENCES[i], length: SEQUENCES[i].length }
  }

  // A CSI sequence the table does not name -- a shifted arrow, a function key
  // -- is still one key, and must not be mistaken for its first byte.
  if (buffer.charAt(0) === ESC && buffer.charAt(1) === "[") {
    var end = 2
    while (end < buffer.length && /[0-9;]/.test(buffer.charAt(end))) end++
    if (end < buffer.length) return { key: buffer.slice(0, end + 1), length: end + 1 }
    return null
  }

  // Alt-modified keys arrive as ESC plus the key. One key, so consume both.
  if (buffer.charAt(0) === ESC && buffer.length > 1) return { key: ESC, length: 1 }

  return { key: buffer.charAt(0), length: 1 }
}

function main() {
  var options = parseArgs(process.argv.slice(2))
  var snapshot
  var model

  try {
    snapshot = loadSnapshot(options.route)
  } catch (e) {
    process.stderr.write("omarchy-dashboard-tui: could not read the menu: " + (e.message || String(e)) + "\n")
    process.exit(1)
    return
  }

  model = TuiModel.create({ snapshot: snapshot })

  var status = ""
  var searching = false
  var height = 0
  // The buffer loop runs keys left over in one read, so a quit has to stop it
  // as well as the process.
  var exited = false

  function write(text) {
    process.stdout.write(text)
  }

  function render() {
    var rows = model.rows()
    var cursor = model.cursor()
    var lines = []
    var title = options.route ? ("Omarchy  " + options.route) : "Omarchy"
    var query = model.query()

    lines.push(BOLD + title + RESET + (searching ? ("  " + query + "▏") : ""))
    lines.push(CSI + "2m" + new Array(Math.max(title.length, 10) + 1).join("-") + RESET)

    var window = visibleRows(rows, height)
    for (var i = 0; i < window.length; i++) {
      var row = window[i]
      var label = row.label || row.id || ""
      if (row.disabled) label += "  " + DIM + "(installed)" + RESET
      if (row.kind === "submenu") label += "  " + DIM + "›" + RESET

      lines.push(cursor === i ? (REVERSE + " " + label + " " + RESET) : ("  " + label))
    }

    if (rows.length === 0) lines.push(DIM + "  nothing here" + RESET)

    lines.push("")
    lines.push(DIM + "↑↓ move   ⏎ open   esc back   / search   r refresh   q quit" + RESET)
    if (status) lines.push(status)

    write(CLEAR + HOME + lines.join("\n"))
  }

  function refreshGuards() {
    try {
      snapshot = loadSnapshot(options.route)
    } catch (e) {
      status = "refresh failed: " + (e.message || String(e))
      return
    }

    model.guardRefresh(snapshot)
    status = ""
  }

  function restore() {
    write(SHOW_CURSOR + ALT_SCREEN_OFF)
    if (process.stdin.isTTY) process.stdin.setRawMode(false)
    process.stdin.pause()
  }

  process.stdin.setRawMode(true)
  process.stdin.resume()
  process.stdin.setEncoding("utf8")
  write(ALT_SCREEN_ON + HIDE_CURSOR + CLEAR)

  process.on("exit", restore)

  var size = function() {
    height = Math.max(3, (process.stdout.rows || 24) - 6)
  }

  process.stdout.on("resize", function() {
    size()
    render()
  })
  size()
  render()

  var pending = ""

  process.stdin.on("data", function(chunk) {
    pending += String(chunk)

    while (pending.length > 0) {
      var decoded = decodeKey(pending)
      // An incomplete escape sequence: wait for the rest rather than acting on
      // a fragment of it.
      if (!decoded) return

      pending = pending.slice(decoded.length)
      handleKey(decoded.key)

      if (exited) return
    }
  })

  function handleKey(key) {

    if (searching) {
      if (key === ESC || key === "") {
        searching = false
        model.setQuery("")
      } else if (key === "\r" || key === "\n") {
        searching = false
      } else if (key === "" || key === "\b") {
        model.setQuery(model.query().slice(0, -1))
      } else if (key >= " ") {
        model.setQuery(model.query() + key)
      }

      render()
      return
    }

    if (key === KEYS.up || key === "k") model.nextRow(-1)
    else if (key === KEYS.down || key === "j") model.nextRow(1)
    else if (key === KEYS.right || key === "l" || key === "\r" || key === "\n") {
      var row = model.current()

      if (row && String(row.kind) === "submenu" && model.descend()) {
        status = ""
      } else {
        var action = model.actionFor(row)
        if (!action) {
          status = row ? ("nothing to run for " + (row.label || row.id)) : "nothing to run"
        } else if (row.disabled) {
          status = (row.label || row.id) + " is already installed"
        } else {
          // Leave the alternate screen first: the action is an ordinary
          // command that may want the whole terminal, and a prompt drawn under
          // a full-screen TUI is a prompt nobody can read.
          restore()
          childProcess.spawnSync("bash", ["-lc", action], { stdio: "inherit" })
          exited = true
          process.exit(0)
        }
      }
    } else if (key === KEYS.left || key === "h" || key === ESC || key === "") {
      if (!model.back()) {
        restore()
        exited = true
        process.exit(0)
      }
      status = ""
    } else if (key === "/") {
      searching = true
    } else if (key === "r") {
      refreshGuards()
    } else if (key === "q") {
      restore()
      exited = true
      process.exit(0)
      return
    }

    render()
  }
}

main()
