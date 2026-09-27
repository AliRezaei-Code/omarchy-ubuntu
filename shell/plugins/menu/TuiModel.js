// The dashboard TUI's logic, with no terminal in it.
//
// Everything here is a pure function of the snapshot and the user's keys, so
// the whole navigate-descend-act-return loop is testable without a tty. The
// drawing, the raw mode and the key decoding live in
// bin/omarchy-dashboard-tui.js, which is the same split docs/menu.md already
// draws between Menu.qml and MenuModel.js: a front end renders, this decides.
//
// ES5 on purpose, like every other model in shell/. Jammy's nodejs is 12, and
// Quickshell's QML engine loads the same files.

var AppSearch = null

try {
  if (typeof require !== "undefined") AppSearch = require("../services/AppSearch.js")
} catch (e) {
  // Quickshell has no CommonJS loader. Search then degrades to a plain
  // substring match rather than the launcher ranking; the shell's own search
  // still does the ranking, and the TUI is a separate front end anyway.
}

function childNodes(node) {
  if (!node || !node.children) return []
  return node.children
}

function rowKey(row) {
  return String((row && row.id) || "")
}

function rowPath(row) {
  return String((row && row.path) || rowKey(row))
}

// The launcher's scorer, applied to menu rows rather than desktop entries.
// Reusing it is the point: a query that ranks a launcher app first should rank
// the same menu row first, and a second implementation would drift.
function searchScore(row, query) {
  if (!query) return 0

  if (AppSearch) {
    var score = AppSearch.fuzzyScore({
      name: String(row.label || ""),
      genericName: String(row.description || ""),
      comment: String(row.title || ""),
      keywords: [rowPath(row)],
      id: rowKey(row)
    }, query)

    if (score >= 0) return score
  }

  var haystack = (row.label + " " + (row.title || "") + " " + (row.description || "") + " " + rowPath(row)).toLowerCase()
  return haystack.indexOf(String(query).toLowerCase()) < 0 ? -1 : 0
}

function create(options) {
  options = options || {}

  var snapshot = options.snapshot || { route: "", tree: { id: "root", kind: "submenu", label: "", children: [] } }
  var byId = {}

  // One flat index of everything the snapshot contains, so a link can be
  // followed and a refreshed path re-found without walking the tree.
  function index(node) {
    if (!node || !node.id) return
    if (!byId[node.id]) byId[node.id] = node
    var children = childNodes(node)
    for (var i = 0; i < children.length; i++) index(children[i])
  }

  function currentNode() {
    if (path.length === 0) return snapshot.tree
    return byId[path[path.length - 1]] || null
  }

  function currentLevel() {
    var node = currentNode()
    if (!node) return []
    return childNodes(node)
  }

  function ordered() {
    var rows = currentLevel()
    if (!query) return rows

    var scored = []
    for (var i = 0; i < rows.length; i++) {
      var score = searchScore(rows[i], query)
      if (score < 0) continue
      scored.push({ row: rows[i], score: score, key: String(rows[i].label || "").toLowerCase() })
    }

    scored.sort(function(a, b) {
      if (a.score !== b.score) return b.score - a.score
      if (a.key < b.key) return -1
      if (a.key > b.key) return 1
      return 0
    })

    var out = []
    for (var j = 0; j < scored.length; j++) out.push(scored[j].row)
    return out
  }

  var rows = []
  var cursor = 0
  var path = []
  var query = ""

  function clamp() {
    if (rows.length === 0) {
      cursor = 0
      return
    }
    if (cursor < 0) cursor = 0
    if (cursor >= rows.length) cursor = rows.length - 1
  }

  function reload(keepPath) {
    // A path the refreshed tree no longer has is a path the user cannot be on
    // any more. Drop back to the deepest level that still exists rather than
    // showing rows from somewhere they never navigated to.
    while (path.length > 0 && !byId[path[path.length - 1]]) path.pop()
    if (!keepPath) cursor = 0
    rows = ordered()
    clamp()
  }

  var model = {
    rows: function() {
      return rows
    },

    cursor: function() {
      return cursor
    },

    path: function() {
      return path.slice()
    },

    query: function() {
      return query
    },

    current: function() {
      return cursor >= 0 && cursor < rows.length ? rows[cursor] : null
    },

    setQuery: function(value) {
      query = String(value == null ? "" : value)
      cursor = 0
      rows = ordered()
      clamp()
      return model
    },

    // Wrapping, not clamping: a list that stops at the end reads as broken,
    // and the key that moves the cursor is the one a user presses most.
    nextRow: function(delta) {
      if (rows.length === 0) {
        cursor = 0
        return model
      }

      var step = Number(delta) || 0
      cursor = (((cursor + step) % rows.length) + rows.length) % rows.length
      return model
    },

    descend: function() {
      var row = model.current()
      if (!row) return false
      if (String(row.kind || "") !== "submenu") return false
      if (childNodes(row).length === 0 && !row.provider) return false

      path.push(row.id)
      cursor = 0
      rows = ordered()
      clamp()
      return true
    },

    back: function() {
      if (path.length === 0) return false

      path.pop()
      cursor = 0
      rows = ordered()
      clamp()
      return true
    },

    // What Enter runs. A link runs whatever its target runs, so the user does
    // not have to know whether a row happens to be spelled as a link. A submenu
    // with nothing in it is not an action at all, and returning null is what
    // lets the front end say so instead of running nothing.
    actionFor: function(row) {
      if (!row) return null

      if (row.action) return String(row.action)

      if (row.target) {
        var target = byId[row.target]
        if (target && target.action) return String(target.action)
        return null
      }

      return null
    },

    // Guards re-evaluate under the user's hands: a package appears, a theme
    // goes away, a submenu empties. The cursor is held by path, because a
    // row's index is not a thing that survives a rebuild -- one new row
    // sorting in above it would otherwise move the selection silently.
    guardRefresh: function(next) {
      if (next) {
        snapshot = next
        byId = {}
        index(snapshot.tree)
      }

      var row = model.current()
      var held = row ? rowPath(row) : null

      rows = ordered()

      if (held) {
        cursor = -1
        for (var i = 0; i < rows.length; i++) {
          if (rowPath(rows[i]) === held) {
            cursor = i
            break
          }
        }
        if (cursor < 0) cursor = 0
      } else {
        cursor = 0
      }

      clamp()
      return model
    },

    nodeById: function(id) {
      return byId[id] || null
    }
  }

  index(snapshot.tree)
  rows = ordered()

  return model
}

if (typeof module !== "undefined") {
  module.exports = {
    create: create,
    searchScore: searchScore
  }
}
