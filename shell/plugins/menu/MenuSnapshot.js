// The Omarchy menu, fully resolved, as a plain object.
//
// The GTK dashboard and the terminal dashboard are two front ends for one menu.
// If either of them decided visibility, disabled state or provider rows for
// itself, they would eventually disagree with each other and with the
// Quickshell shell, and the row a user is looking at would stop meaning what it
// says. So neither of them decides anything: this module answers every question
// the menu raises and the front ends draw what it hands back.
//
// Everything a decision depends on comes from MenuModel.js -- the same
// parse, the same merge, the same `isVisible`, the same `displayRow`, the same
// generated guard script -- because that file is what the shell runs. Where a
// second implementation would have been faster to write it would also have been
// a second answer, which is the one thing this file exists to prevent.
//
// ES5 on purpose, like every other model in shell/. Jammy's nodejs is 12, and
// nothing here may assume a newer parser.

var MenuModel = null
var fs = null
var childProcess = null

try {
  if (typeof require !== "undefined") {
    MenuModel = require("./MenuModel.js")
    fs = require("fs")
    childProcess = require("child_process")
  }
} catch (e) {
  // Quickshell has no CommonJS loader. Nothing below is reachable there --
  // the shell never loads this file, it reads the JSON this produces -- so a
  // null model only has to fail loudly if something asks for it anyway.
}

// The two files the shell reads, at the two places it reads them from. See
// docs/menu.md: the shipped menu is data inside the package and the overlay is
// the user's, and an overlay that is absent is the normal case rather than a
// fault -- Menu.qml does the same on load failure.
var SHIPPED_MENU = "default/omarchy/omarchy-menu.jsonc"
var USER_MENU = ".config/omarchy/extensions/omarchy-menu.jsonc"
var PACKAGED_PATH = "/usr/share/omarchy"

// Guard recursion in MenuModel stops at 32 levels; the same bound applies here
// so an extension that declares a `parent` cycle cannot spin.
var MAX_DEPTH = 32

var USAGE = [
  "Usage: omarchy-menu-snapshot [--route=<id>] [--providers] [--no-guards] [--pretty]",
  "",
  "Prints the fully-resolved Omarchy menu tree as JSON on stdout.",
  "",
  "  --route=<id>   Resolve one subtree by item id or declared alias (style.theme, style).",
  "  --providers    Run the bash providers and merge their rows into their submenus.",
  "  --no-guards    Skip guard evaluation; every guard reads as unevaluated.",
  "  --pretty       Indent the JSON.",
  ""
].join("\n")

function env() {
  if (typeof process !== "undefined" && process && process.env) return process.env
  return ({ })
}

// --- the tree ---------------------------------------------------------------

// The root the menu files are read from, in the order a caller can override it.
// `omarchyPath` is the shell's own name for the tree and wins; `root` is what a
// test harness pins; then the two environment variables, which is how a
// packaged install and a checkout each find their own.
function treeRoot(options) {
  if (options.omarchyPath) return String(options.omarchyPath)
  if (options.root) return String(options.root)
  var environment = env()
  if (environment.ROOT) return environment.ROOT
  if (environment.OMARCHY_PATH) return environment.OMARCHY_PATH
  return PACKAGED_PATH
}

function readFile(file) {
  try {
    return { ok: true, text: fs.readFileSync(file, "utf8") }
  } catch (e) {
    return { ok: false, reason: String((e && e.message) || e) }
  }
}

function loadShippedMenu(rootDir) {
  var file = rootDir + "/" + SHIPPED_MENU
  var read = readFile(file)
  if (!read.ok) return { error: "cannot read " + file + ": " + read.reason }
  var entries = MenuModel.parseMenuJsonc(read.text)
  // An empty shipped menu is not an empty menu, it is an unreadable one: the
  // file parsed to nothing because it is broken, and answering with a root
  // and no rows would be a front end rendering a dashboard that says there is
  // nothing to install, which is a lie rather than an answer.
  if (entries.length === 0) return { error: file + " declares no menu entries" }
  return { items: entries }
}

function loadUserMenu(homeDir) {
  if (!homeDir) return []
  var read = readFile(homeDir + "/" + USER_MENU)
  // The shell drops a user extension that will not load, rather than failing
  // the whole menu, and a snapshot that diverged here would be the one place
  // the two front ends stopped agreeing.
  if (!read.ok) return []
  return MenuModel.parseMenuJsonc(read.text)
}

// --- guards -----------------------------------------------------------------

// Which package manager answers the batch. The generated script asks the
// machine this same question when nothing pins it, so the snapshot asks it too
// and then pins the answer, which means the backend it reports and the branch
// the guards actually ran cannot come apart.
function onPath(name) {
  // Read once, outside the loop: a runtime without fs.constants would
  // otherwise throw on every directory and quietly answer "not installed" for
  // everything, which is the kind of wrong this whole file exists to avoid.
  var mode = (fs.constants && fs.constants.X_OK !== undefined) ? fs.constants.X_OK : 1
  var directories = String(env().PATH || "").split(":")

  for (var i = 0; i < directories.length; i++) {
    if (!directories[i]) continue
    try {
      fs.accessSync(directories[i] + "/" + name, mode)
      return true
    } catch (e) { }
  }

  return false
}

function resolveBackend(options) {
  if (options.backend === "arch" || options.backend === "deb") return options.backend

  var declared = env().OMARCHY_PKG_BACKEND
  if (declared === "arch" || declared === "deb") return declared

  if (onPath("pacman")) return "arch"
  if (onPath("dpkg-query")) return "deb"

  // Neither is installed. The generated batch falls through to the dpkg
  // snapshot in that case, so "deb" is what the guards used rather than a
  // third backend nothing ran.
  return "deb"
}

// One process for every `when:`, `checked:` and `disabled:` in the menu. The
// shipped menu asks hundreds of questions and asked one at a time it spends
// seconds; the whole point of the batch is that it does not.
function evaluateGuards(items, backend, rootDir) {
  var result = { evaluated: false, count: 0, when: ({ }), checked: ({ }), disabled: ({ }) }
  var script = MenuModel.guardScript(items, backend)
  if (!script) return result

  // The batch reads the package name map from $OMARCHY_PATH, because that is
  // where the real omarchy-pkg-present reads it from. Without this the
  // snapshot would answer a renamed package differently from the command it
  // stands in for, which is the disagreement this file exists to prevent. An
  // OMARCHY_PATH the caller already set is left alone: their machine's answer
  // outranks the one this module would derive.
  var environment = ({ })
  var inherited = env()
  for (var key in inherited) environment[key] = inherited[key]
  if (!environment.OMARCHY_PATH) environment.OMARCHY_PATH = rootDir

  var run = childProcess.spawnSync("bash", ["-c", script], { encoding: "utf8", env: environment })
  if (run.error) {
    result.error = "guard batch did not run: " + String(run.error.message || run.error)
    return result
  }
  if (run.status !== 0) {
    // A batch that died has only told us about the rows it reached, and a row
    // whose `when:` went unanswered shows. Reporting the rows that did land
    // would be a snapshot that hides half the menu for no reason, so the whole
    // answer is dropped and the tree falls back to what the shell shows while
    // its first evaluation is still running.
    result.error = "guard batch exited " + run.status
    return result
  }

  // `<id>:<w|c|d>:<0|1>` per line, split from the right so an id containing a
  // colon still reads. Identical to the shell's own parse of the same lines.
  var lines = String(run.stdout || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var colon = line.lastIndexOf(":")
    if (colon < 0) continue
    var value = line.substring(colon + 1) === "1"
    var rest = line.substring(0, colon)
    var tagAt = rest.lastIndexOf(":")
    if (tagAt < 0) continue
    var id = rest.substring(0, tagAt)
    var tag = rest.substring(tagAt + 1)
    if (tag === "w") result.when[id] = value
    else if (tag === "c") result.checked[id] = value
    else if (tag === "d") result.disabled[id] = value
    else continue
    result.count += 1
  }

  result.evaluated = true
  return result
}

// --- providers --------------------------------------------------------------

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

// The shell's providers, as the shell declares them. Adding one here is only
// correct alongside an entry in the `providers` map in Menu.qml: a provider an
// extension points at is one of these names, and the row contract is
// `label\tvalue\tcurrent` per line.
var PROVIDERS = {
  "fonts": {
    script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
    icon: "",
    volatile: true,
    actionFor: function(value) { return "omarchy-font-set " + shellQuote(value) }
  },
  "power-profiles": {
    script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
    icon: "\udb81\udc0b",
    actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + shellQuote(value) }
  }
}

// `apps` is the one provider with no script behind it. Menu.qml hands it to the
// shell's AppLibrary, a Quickshell object over DesktopEntries that carries
// image icons, launch feedback and uninstall support; there is no enumeration
// here that would answer with the same rows, and a front end drawing a
// different list of applications than the shell is exactly the disagreement
// this module is for. So it is reported as unresolved and the submenu stays in
// the tree with nothing in it, which is what a provider-backed submenu with no
// rows yet means anyway.
function providerUnavailable(name) {
  if (name === "apps") {
    return "apps: provider is QML-native (shell AppLibrary); no rows outside the Quickshell shell"
  }
  return name + ": no such provider is defined in the shell"
}

function providerRows(spec, menuId, output) {
  var rows = []
  var takenIds = ({ })
  var lines = String(output || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue

    var parts = line.split("\t")
    var label = parts[0] || ""
    var value = parts[1] || parts[0] || ""
    var current = parts[2] || ""
    if (!label) continue

    // Distinct values can slugify alike -- Fira Code and Fira-Code both give
    // fira-code -- and a repeated id is dropped by the merge, which would
    // silently lose a row. Nudge it until the row has an id of its own.
    var rowId = menuId + "." + MenuModel.slugify(value)
    while (takenIds[rowId]) rowId += "-"
    takenIds[rowId] = true

    rows.push({
      id: rowId,
      parent: menuId,
      kind: "action",
      icon: (value === current) ? "✓" : (spec.icon || ""),
      label: label,
      title: "",
      target: "",
      description: "",
      action: spec.actionFor(value),
      provider: "",
      aliases: [],
      when: "",
      checked: "",
      disabled: "",
      order: 0
    })
  }

  return rows
}

function resolveProviders(state) {
  var result = { resolved: true, errors: ({ }) }
  var order = state.itemOrder

  for (var i = 0; i < order.length; i++) {
    var entry = MenuModel.item(state.items, order[i])
    if (!entry || !entry.provider) continue

    var spec = PROVIDERS[entry.provider]
    if (!spec) {
      result.errors[entry.id] = providerUnavailable(entry.provider)
      continue
    }

    // `bash -c` rather than the shell's `bash -lc`: a login shell re-reads
    // /etc/profile, which on Debian replaces PATH outright and would throw
    // away the environment -- including the tree root -- the command was
    // invoked with. The scripts are enumerations over commands already on
    // PATH, so both forms answer the same thing and only one of them answers
    // it for the machine that asked.
    var run = childProcess.spawnSync("bash", ["-c", spec.script], { encoding: "utf8" })
    if (run.error) {
      result.errors[entry.id] = entry.provider + ": did not run: " + String(run.error.message || run.error)
      continue
    }
    if (run.status !== 0) {
      result.errors[entry.id] = entry.provider + ": exited " + run.status
      continue
    }

    // One provider failing is one empty submenu, never an empty menu: the
    // failure is recorded and the rest of the providers still run.
    var merged = MenuModel.swapProviderRows(state.items, state.itemOrder, entry.id, providerRows(spec, entry.id, run.stdout))
    state.items = merged.items
    state.itemOrder = merged.itemOrder
  }

  return result
}

// --- the tree ---------------------------------------------------------------

// Kind as a front end has to draw it, not as the model stores it. A node with
// children or a provider opens into something, whatever else it declares; a
// `target:` makes the row a pointer at another submenu; anything else runs.
function nodeKind(entry, hasChildren) {
  if (hasChildren || entry.provider) return "submenu"
  if (entry.target) return "link"
  return "action"
}

function buildNode(state, id, depth) {
  var entry = MenuModel.item(state.items, id)
  if (!entry || depth > MAX_DEPTH) return null

  var children = []
  var order = state.itemOrder
  for (var i = 0; i < order.length; i++) {
    var child = MenuModel.item(state.items, order[i])
    if (!child || child.parent !== id) continue
    // The shell's own visibility, called exactly as Menu.qml calls it: a row
    // whose `when:` failed is gone, a submenu with no visible descendants goes
    // with them, and a provider-backed one stays because its rows load on
    // demand.
    if (!MenuModel.isVisible(state.items, state.itemOrder, state.whenResults, child)) continue
    var node = buildNode(state, child.id, depth + 1)
    if (node) children.push(node)
  }

  // displayRow is the shell's row, so the label the user reads, the dimmed
  // state, the path and the row a selection navigates to are the shell's own
  // answers rather than this file's reading of the same entry.
  var row = MenuModel.displayRow(state.items, state.itemOrder, state.checkedResults, state.disabledResults, entry, "", 0, "")

  // A ✓ goes on a row whose `checked:` succeeded and on one whose `disabled:`
  // did, since a dimmed install row means the same thing the marker means
  // everywhere else. Both are reported, so a front end can draw the marker as
  // an icon and still hand back the label the shell would have shown.
  var checked = (entry.checked && state.checkedResults[entry.id])
    || MenuModel.isDisabled(state.disabledResults, entry)

  return {
    id: entry.id,
    label: row.label,
    title: entry.title || entry.label,
    description: entry.description,
    icon: row.icon,
    kind: nodeKind(entry, children.length > 0),
    disabled: row.disabled,
    checked: !!checked,
    children: children,
    action: row.action,
    target: entry.target,
    route: row.target,
    depth: MenuModel.depthFor(state.items, entry.id),
    path: row.path,
    provider: entry.provider
  }
}

// --- the snapshot -----------------------------------------------------------

function emptySnapshot() {
  return {
    root: "root",
    route: "root",
    backend: "",
    items: ({ }),
    tree: null,
    guards: { evaluated: false, count: 0 },
    providers: { resolved: false, errors: ({ }) }
  }
}

function buildSnapshot(options) {
  options = options || {}

  var snapshot = emptySnapshot()
  if (!MenuModel || !fs || !childProcess) {
    snapshot.error = "MenuSnapshot.js needs a CommonJS loader and Node's fs and child_process"
    return snapshot
  }

  var rootDir = treeRoot(options)
  var shipped = loadShippedMenu(rootDir)
  if (shipped.error) {
    snapshot.error = shipped.error
    return snapshot
  }

  var merged = MenuModel.mergeMenuSources(shipped.items, loadUserMenu(env().HOME))
  var state = {
    items: merged.items,
    itemOrder: merged.itemOrder,
    whenResults: ({ }),
    checkedResults: ({ }),
    disabledResults: ({ })
  }

  snapshot.backend = resolveBackend(options)

  if (options.guards !== false) {
    var guards = evaluateGuards(state.items, snapshot.backend, rootDir)
    state.whenResults = guards.when
    state.checkedResults = guards.checked
    state.disabledResults = guards.disabled
    snapshot.guards = { evaluated: guards.evaluated, count: guards.count }
    if (guards.error) snapshot.guards.error = guards.error
  }

  if (options.providers === true) {
    snapshot.providers = resolveProviders(state)
  }

  // Providers contribute rows to submenus that may themselves sit outside the
  // route, so the route is resolved after they have run.
  var route = MenuModel.resolveRoute(state.items, state.itemOrder, options.route)
  if (!MenuModel.item(state.items, route)) {
    snapshot.error = "unknown route '" + route + "'"
    return snapshot
  }
  snapshot.route = route

  // A route the caller asked for is opened even if its own `when:` would have
  // hidden it, which is what summoning a route does in the shell. Its children
  // are still filtered.
  var tree = buildNode(state, route, 0)
  if (!tree) {
    snapshot.error = "route '" + route + "' could not be resolved"
    return snapshot
  }

  snapshot.items = state.items
  snapshot.tree = tree
  return snapshot
}

// --- the command ------------------------------------------------------------

function parseArgs(argv) {
  var options = { route: "", providers: false, guards: true, pretty: false }
  var args = Array.isArray(argv) ? argv : []

  for (var i = 0; i < args.length; i++) {
    var arg = String(args[i])
    if (arg === "--providers") options.providers = true
    else if (arg === "--no-guards") options.guards = false
    else if (arg === "--pretty") options.pretty = true
    else if (arg.indexOf("--route=") === 0) options.route = arg.substring(8)
    else if (arg === "--route") {
      if (i + 1 >= args.length) return { error: "--route requires a value" }
      options.route = String(args[++i])
    } else if (arg === "-h" || arg === "--help") return { help: true }
    else return { error: "unknown argument '" + arg + "'" }
  }

  return options
}

function main(argv) {
  var options = parseArgs(argv)
  if (options.help) {
    process.stdout.write(USAGE)
    return 0
  }
  if (options.error) {
    process.stderr.write("omarchy-menu-snapshot: " + options.error + "\n\n" + USAGE)
    return 2
  }

  var snapshot = buildSnapshot(options)
  if (snapshot.error) {
    // The error is JSON on stderr and the exit is nonzero, so a caller reading
    // either end gets a parsed answer rather than a stack trace. A tree that
    // cannot be read is a fact about the machine, not a crash.
    process.stderr.write(JSON.stringify({ error: snapshot.error }) + "\n")
    return 1
  }

  var json = options.pretty ? JSON.stringify(snapshot, null, 2) : JSON.stringify(snapshot)
  process.stdout.write(json + "\n")
  return 0
}

if (typeof module !== "undefined") {
  module.exports = {
    buildSnapshot: buildSnapshot,
    providers: PROVIDERS,
    parseArgs: parseArgs,
    main: main
  }
}

if (typeof require !== "undefined" && typeof module !== "undefined" && require.main === module) {
  // `omarchy menu snapshot | head` closes the pipe while the answer is still
  // being written. That is a normal thing to do with a command whose output
  // is JSON, and a stack trace about it helps nobody.
  process.stdout.on("error", function(error) {
    if (error && error.code === "EPIPE") process.exit(0)
    throw error
  })

  // `process.exitCode` rather than `process.exit()`: a write to a pipe is
  // asynchronous, and exiting outright cuts the answer off at whatever the
  // pipe has already taken -- for a full menu, somewhere past 64 KiB.
  process.exitCode = main(process.argv.slice(2))
}
