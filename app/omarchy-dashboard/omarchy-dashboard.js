#!/usr/bin/gjs
// The Omarchy dashboard, as a window.
//
// This file draws and nothing else. It runs `omarchy menu snapshot` and
// renders the JSON it gets back: which rows exist, which are dimmed, which
// carry a check, what a row would run. Deciding any of that here would be a
// second answer to the same question MenuModel.js already answers for the
// Quickshell menu and TuiModel.js already answers for the terminal, and two
// front ends that disagree about whether a row is usable are worse than one
// surface. So the app has no idea what a guard means; it reads the verdict.
//
// GJS is ESM, so there is no CommonJS loader to reach for: nothing here loads
// AppSearch.js the way the terminal front end does, and the tree root comes
// from the environment with a path derived from import.meta.url behind it.

import Gdk from 'gi://Gdk?version=4.0'
import Gio from 'gi://Gio?version=2.0'
import GLib from 'gi://GLib?version=2.0'
import GObject from 'gi://GObject?version=2.0'
import Gtk from 'gi://Gtk?version=4.0'
import Adw from 'gi://Adw?version=1'
import Pango from 'gi://Pango?version=1.0'

const APP_ID = 'org.omarchy.Dashboard'

// The menu's icon column is Nerd Font private-use codepoints, and an
// application only renders the fonts the system has. A stock Ubuntu 22.04 has
// none, so every glyph in that column is a tofu box -- and a window full of
// boxes reads as a broken app, not as missing decoration. So a codepoint
// outside the Basic Multilingual Plane is dropped unless the font that draws
// it is actually installed, which is what a packaged Omarchy provides and what
// a checkout on a bare system does not.
function renderableGlyph(icon) {
  const value = String(icon || '')
  if (!value) return ''

  for (const character of value) {
    const point = character.codePointAt(0)
    // Private Use Area, and the two supplementary private-use ranges Nerd
    // Fonts also draw from.
    const privateUse =
      (point >= 0xe000 && point <= 0xf8ff) ||
      (point >= 0xf0000 && point <= 0xffffd) ||
      (point >= 0x100000 && point <= 0x10fffd)
    if (!privateUse) return value
  }

  return ''
}

function omarchyFontInstalled() {
  const home = GLib.get_home_dir()
  const candidates = [
    GLib.build_filenamev([home, '.local', 'share', 'fonts', 'omarchy.ttf']),
    GLib.build_filenamev([home, '.local', 'share', 'fonts', 'omarchy', 'omarchy.ttf']),
    '/usr/share/fonts/omarchy/omarchy.ttf',
    '/usr/local/share/fonts/omarchy/omarchy.ttf'
  ]

  return candidates.some((path) => GLib.file_test(path, GLib.FileTest.EXISTS))
}

function nodeGlyph(node) {
  return omarchyFontInstalled() ? renderableGlyph(node && node.icon) : ''
}const WINDOW_TITLE = 'Omarchy'
const REFRESH_DEBOUNCE_MS = 250

// --- the tree ---------------------------------------------------------------

// Which tree this is. $OMARCHY_PATH is the packaged contract and the wrapper
// sets it to the tree it was launched from, so a checkout reads the checkout's
// menu. The import.meta fallback is what makes `gjs -m` on the file directly do
// the same thing rather than silently reading an installed tree instead.
function omarchyRoot() {
  const fromEnv = GLib.getenv('OMARCHY_PATH')
  if (fromEnv && fromEnv.length > 0 && !fromEnv.endsWith('/'))
    return fromEnv

  if (fromEnv && fromEnv.endsWith('/'))
    return fromEnv.slice(0, -1)

  // Gio.File rather than GLib.filename_from_uri: GJS overrides the latter to
  // return a [name, host] pair, and a pair handed back to path_get_dirname is
  // an exception rather than a directory.
  const here = Gio.File.new_for_uri(import.meta.url).get_parent()
  return here.get_parent().get_path()
}

const ROOT = omarchyRoot()
const BIN_DIR = GLib.build_filenamev([ROOT, 'bin'])

// The two files `omarchy menu snapshot` reads, so the app watches the same two
// the shell watches. docs/menu.md promises edits to either take effect without
// a restart, and a menu that needs a restart to notice a typo is the reason
// people stop editing it.
function menuFiles() {
  const home = GLib.get_home_dir()
  return [
    GLib.build_filenamev([ROOT, 'default', 'omarchy', 'omarchy-menu.jsonc']),
    GLib.build_filenamev([home, '.config', 'omarchy', 'extensions', 'omarchy-menu.jsonc'])
  ]
}

function omarchyBinary() {
  const path = GLib.build_filenamev([BIN_DIR, 'omarchy'])
  return GLib.file_test(path, GLib.FileTest.EXISTS) ? path : 'omarchy'
}

// --- the theme --------------------------------------------------------------

// Where the live theme lives. It is a symlink onto whichever theme is active,
// so reading through it is always reading the current one. The file is
// rendered from default/themed/shell.toml.tpl, which is why the values here
// are colours and alpha numbers rather than {{ placeholders }}.
const THEME_STATE = '.local/state/omarchy/current/theme'

function themeFile(name) {
  return GLib.build_filenamev([GLib.get_home_dir(), THEME_STATE, name])
}

// A rendered shell.toml value: "#rrggbb", "#rrggbbaa", "rgb(r, g, b)",
// "rgba(r, g, b, a)", or a Hyprland-style gradient such as
// "rgba(...) rgba(...) 45deg" whose first stop is the only part a single-colour
// consumer can use. Anything else -- a token reference, a name -- is not a
// colour and is reported as null so the caller falls back.
function parseColor(value) {
  if (typeof value !== 'string')
    return null

  const text = value.trim().replace(/^["']|["']$/g, '')
  if (text.length === 0)
    return null

  const hex = /^#([0-9a-fA-F]{3,8})$/.exec(text)
  if (hex) {
    const digits = hex[1]
    const expand = d => d.length === 3 || d.length === 4
      ? d.split('').map(c => c + c).join('')
      : d

    if (digits.length === 3 || digits.length === 4 || digits.length === 6 || digits.length === 8) {
      const full = expand(digits)
      return {
        r: parseInt(full.slice(0, 2), 16),
        g: parseInt(full.slice(2, 4), 16),
        b: parseInt(full.slice(4, 6), 16),
        a: full.length === 8 ? parseInt(full.slice(6, 8), 16) / 255 : 1
      }
    }

    return null
  }

  // A gradient's first stop is the one a flat consumer can honour, and taking
  // it is better than discarding a token that does have a colour in it.
  const stop = /^rgba?\s*\(([^)]*)\)/.exec(text)
  if (stop) {
    const parts = stop[1].split(',').map(p => parseFloat(p.trim()))
    if (parts.length >= 3 && parts.slice(0, 3).every(n => !isNaN(n))) {
      let alpha = parts.length > 3 && !isNaN(parts[3]) ? parts[3] : 1
      if (alpha > 1) alpha /= 100
      return {
        r: Math.round(parts[0]),
        g: Math.round(parts[1]),
        b: Math.round(parts[2]),
        a: Math.min(Math.max(alpha, 0), 1)
      }
    }
  }

  return null
}

function parseAlpha(value) {
  const number = parseFloat(String(value == null ? '' : value).trim())
  if (isNaN(number))
    return null
  return Math.min(Math.max(number > 1 ? number / 100 : number, 0), 1)
}

function hex(r, g, b) {
  const channel = n => Math.round(Math.min(Math.max(n, 0), 255)).toString(16).padStart(2, '0')
  return '#' + channel(r) + channel(g) + channel(b)
}

// Colours compose rather than blend, because CSS alpha over a window
// background is a guess about what is behind the window and a flattened colour
// is not: the same token reads correctly on a light and a dark theme.
function over(color, alpha, backdrop) {
  if (!color)
    return null

  const a = Math.min(Math.max(alpha == null ? 1 : alpha, 0), 1) * (color.a == null ? 1 : color.a)
  if (!backdrop)
    return hex(color.r, color.g, color.b)

  return hex(
    color.r * a + backdrop.r * (1 - a),
    color.g * a + backdrop.g * (1 - a),
    color.b * a + backdrop.b * (1 - a)
  )
}

// One TOML section, as a plain map. Only `key = value` at the top level of the
// named section is kept: the rendered shell.toml has no nesting, and anything
// that is not a section header ends the section it was in. An empty name is the
// implicit top-level section, which is where colors.toml keeps `mode`.
//
// A missing file is the normal case on a machine that has never set a theme,
// and GLib.file_get_contents raises rather than returning a false flag, so the
// absence is checked before the read and the read is still guarded.
function readTomlSection(path, section) {
  let text = null

  try {
    const [ok, bytes] = GLib.file_get_contents(path)
    if (ok)
      text = new TextDecoder().decode(bytes)
  } catch (e) {
    return null
  }

  if (text === null)
    return null

  const values = {}
  let inside = section === ''

  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.length === 0 || line.startsWith('#'))
      continue

    const header = /^\[([^\]]+)\]$/.exec(line)
    if (header) {
      inside = header[1].trim() === section
      continue
    }

    if (!inside)
      continue

    const pair = /^([A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line)
    if (pair)
      values[pair[1]] = pair[2].trim()
  }

  return Object.keys(values).length > 0 ? values : null
}

// mode lives in colors.toml beside shell.toml, and it is the theme saying
// outright whether it is a light or a dark one. Adw.StyleManager is the
// supported way to answer that in libadwaita 1.x -- the
// gtk-application-prefer-dark-theme setting is not.
function themeMode() {
  const values = readTomlSection(themeFile('colors.toml'), '')
  if (!values)
    return null

  const mode = String(values.mode || '').toLowerCase()
  return mode === 'light' ? 'light' : mode === 'dark' ? 'dark' : null
}

// The [menu] tokens, flattened onto the window background. Everything libadwaita
// draws that we do not name keeps its own look, so this is a tint rather than a
// re-skin, and the day the theme gains a token nobody reads here it costs
// nothing.
function menuPalette() {
  const values = readTomlSection(themeFile('shell.toml'), 'menu')
  if (!values)
    return null

  const background = parseColor(values.background)
  if (!background)
    return null

  const text = parseColor(values.text) || { r: 255, g: 255, b: 255, a: 1 }
  const backgroundAlpha = parseAlpha(values['background-alpha'])
  const mode = themeMode()

  // A translucent card has to land on something. Dark themes get black and
  // light themes get white, which is what the compositor underneath would have
  // done anyway.
  const backdrop = mode === 'light' ? { r: 255, g: 255, b: 255, a: 1 } : { r: 0, g: 0, b: 0, a: 1 }
  const base = over(background, backgroundAlpha == null ? 1 : backgroundAlpha, backdrop)
  const baseColor = parseColor(base)

  const selected = parseColor(values['selected-background'])
  const selectedAlpha = parseAlpha(values['selected-background-alpha'])
  const accent = parseColor(values['selected-text'])
  const border = parseColor(values.border)

  return {
    background: base,
    text: over(text, 1, baseColor) || base,
    muted: over(text, 0.55, baseColor) || base,
    selection: over(selected, selectedAlpha == null ? 1 : selectedAlpha, baseColor) || base,
    accent: over(accent, 1, baseColor) || over(text, 1, baseColor) || base,
    border: over(border, parseAlpha(values['border-alpha']) == null ? 1 : parseAlpha(values['border-alpha']), baseColor) || over(text, 0.16, baseColor) || base,
    mode: mode
  }
}

function themeCss(palette) {
  return `window.omarchy-dashboard {
  background-color: ${palette.background};
}
.omarchy-dashboard-title {
  color: ${palette.text};
  font-weight: 700;
}
.omarchy-dashboard-description {
  color: ${palette.muted};
  font-size: 0.92em;
}
.omarchy-dashboard-icon {
  color: ${palette.text};
  font-size: 1.35em;
  padding: 2px 4px 2px 2px;
}
.omarchy-dashboard-check {
  color: ${palette.accent};
  -gtk-icon-size: 16px;
}
.omarchy-dashboard-trailing {
  color: ${palette.muted};
  -gtk-icon-size: 16px;
}
.omarchy-dashboard-row {
  border-radius: 10px;
  padding: 7px 10px;
  margin: 1px 6px;
}
.omarchy-dashboard-row-selected {
  background-color: ${palette.selection};
}
.omarchy-dashboard-row-disabled {
  opacity: 0.45;
}
.omarchy-dashboard-heading {
  color: ${palette.text};
  font-weight: 700;
  font-size: 1.15em;
}
.omarchy-dashboard-body {
  color: ${palette.muted};
}
.omarchy-dashboard-mono {
  color: ${palette.muted};
  font-family: monospace;
  font-size: 0.9em;
}
.omarchy-dashboard-border {
  background-color: ${palette.border};
  min-height: 1px;
}
`
}

// --- processes --------------------------------------------------------------

function childEnvironment(launcher) {
  // A window launched from the app grid inherits a session environment with no
  // OMARCHY_PATH in it, and every omarchy-* command the menu runs needs both
  // the tree root and bin/ on PATH. Restoring them here is what stops an action
  // from failing with "command not found" the moment it was started from a
  // desktop icon rather than a login shell.
  launcher.setenv('OMARCHY_PATH', ROOT, true)

  const path = GLib.getenv('PATH')
  launcher.setenv('PATH', BIN_DIR + ':' + (path == null || path.length === 0 ? '/usr/bin:/bin' : path), true)
}

function launcherFor() {
  const launcher = new Gio.SubprocessLauncher({
    flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
  })
  childEnvironment(launcher)
  return launcher
}

// GJS 1.72 can call neither Gio.InputStream.read_all_async nor
// DataInputStream.read_upto_async: both return a caller-allocated byte array
// that the binding refuses to marshal. DataInputStream.read_line_async is the
// one async read that marshals, and it is lossless for text -- it strips the
// newline and the next read resumes after it, so joining the lines back
// reproduces the stream exactly, however many lines there were.
//
// read_line_finish hands back bytes rather than a string, so the decode is
// explicit: relying on Array.toString() to turn a Uint8Array into text is a
// deprecation GJS already warns about, and the JSON parser is the last thing
// that should depend on it.
function readTextAsync(stream, onDone) {
  if (stream === null) {
    onDone('')
    return
  }

  const decoder = new TextDecoder()
  const lines = []
  const reader = new Gio.DataInputStream({ base_stream: stream })

  const next = () => {
    reader.read_line_async(GLib.PRIORITY_LOW, null, (input, result) => {
      let line = null
      try {
        [line] = input.read_line_finish(result)
      } catch (e) {
        onDone(lines.join('\n'))
        return
      }

      if (line === null) {
        onDone(lines.join('\n'))
        return
      }

      lines.push(decoder.decode(line))
      next()
    })
  }

  next()
}

// `omarchy menu snapshot` with the same flags the terminal front end uses:
// no --providers, no --route unless one was asked for. Matching them exactly
// is what makes the two windows comparable -- a row that is in one and not the
// other would be a flag difference, not a disagreement.
// GJS's ARGV holds the arguments after the script name and nothing else, so the
// whole of it is scanned.
function snapshotRoute() {
  for (const arg of ARGV) {
    if (arg.startsWith('--route='))
      return arg.slice('--route='.length)
  }
  return ''
}

function loadSnapshot(onDone) {
  const argv = ['menu', 'snapshot']
  const route = snapshotRoute()
  if (route.length > 0)
    argv.push('--route=' + route)

  let process = null
  try {
    process = launcherFor().spawnv([omarchyBinary()].concat(argv))
  } catch (e) {
    onDone({ ok: false, message: 'could not run ' + omarchyBinary() + ': ' + e.message })
    return
  }

  // The snapshot is the app's whole data source, so its stderr is read as well
  // as its stdout: "no Node.js runtime found" is the single most likely reason
  // this window comes up empty, and swallowing it would leave the user looking
  // at a blank pane with no idea why.
  //
  // Both pipes are drained at once and the result is assembled after both
  // finish. Reading one to EOF before starting the other deadlocks: the
  // snapshot is a few hundred kilobytes, far more than a pipe buffer holds, so
  // the child blocks writing stdout forever while the parent waits for stderr
  // to close.
  let stdout = ''
  let stderr = ''
  let pending = 2

  const settle = () => {
    pending--
    if (pending > 0)
      return

    process.wait_async(null, (waited, waitResult) => {
      let status = -1
      try {
        waited.wait_finish(waitResult)
        status = waited.get_exit_status()
      } catch (e) {
        status = -1
      }

      let parsed = null
      try {
        parsed = JSON.parse(stdout)
      } catch (e) {
        parsed = null
      }

      const detail = stderr.trim().length > 0 ? ': ' + stderr.trim() : ''

      if (parsed !== null && !parsed.error)
        onDone({ ok: true, snapshot: parsed })
      else if (parsed !== null && parsed.error)
        onDone({ ok: false, message: parsed.error })
      else if (status !== 0)
        onDone({ ok: false, message: 'omarchy menu snapshot exited with ' + status + detail })
      else
        onDone({ ok: false, message: 'omarchy menu snapshot printed nothing parseable' + detail })
    })
  }

  readTextAsync(process.get_stdout_pipe(), text => { stdout = text; settle() })
  readTextAsync(process.get_stderr_pipe(), text => { stderr = text; settle() })
}

// A terminal to run it in. Running a command with no window to show it in is
// how a dashboard earns a reputation for being broken, so a row that runs
// something always opens a terminal the user can read and close.
//
// The first entry is the way the rest of the tree does it: `omarchy-launch-tui`
// execs `setsid uwsm-app -- xdg-terminal-exec --app-id=... -e <command>`, and
// the arguments below are that argv verbatim. The rest exist because uwsm and
// xdg-terminal-exec are Wayland-session tools and a plain X session has neither.
function terminalArgv(inner) {
  const uwsm = GLib.find_program_in_path('uwsm-app')
  const xdgTerminal = GLib.find_program_in_path('xdg-terminal-exec')

  if (uwsm && xdgTerminal)
    return ['setsid', uwsm, '--', xdgTerminal, '--app-id=org.omarchy.dashboard', '-e'].concat(inner)

  const candidates = [
    ['foot', inner],
    ['alacritty', ['-e'].concat(inner)],
    ['ghostty', ['-e'].concat(inner)],
    ['kitty', inner],
    ['wezterm', ['start', '--'].concat(inner)],
    ['gnome-terminal', ['--'].concat(inner)],
    ['konsole', ['-e'].concat(inner)],
    ['xfce4-terminal', ['-e'].concat(inner)],
    ['lxterminal', ['-e'].concat(inner)],
    ['mate-terminal', ['-e'].concat(inner)],
    ['tilix', ['-e'].concat(inner)],
    ['terminator', ['-e'].concat(inner)],
    ['xterm', ['-e'].concat(inner)]
  ]

  for (const [name, argv] of candidates) {
    const program = GLib.find_program_in_path(name)
    if (program)
      return [program].concat(argv)
  }

  return null
}

function quoteForShell(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// --- widgets ----------------------------------------------------------------

const ListRow = GObject.registerClass(
class ListRow extends Gtk.ListBoxRow {
  _init(node, onActivate) {
    super._init({ visible: true })
    this.node = node
    this._onActivate = onActivate

    const content = new Gtk.Box({
      orientation: Gtk.Orientation.HORIZONTAL,
      spacing: 12,
      hexpand: true
    })
    content.add_css_class('omarchy-dashboard-row')

    const icon = new Gtk.Label({ label: nodeGlyph(node), valign: Gtk.Align.CENTER })
    icon.add_css_class('omarchy-dashboard-icon')
    // An empty glyph column would indent every row that has no icon, and the
    // shipped menu is mixed, so a row without one starts where its label does.
    icon.visible = String(node.icon || '').length > 0
    content.append(icon)

    const labels = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 2, hexpand: true })
    const title = new Gtk.Label({
      label: String(node.label || node.id || ''),
      xalign: 0,
      ellipsize: Pango.EllipsizeMode.END,
      single_line_mode: true
    })
    title.add_css_class('omarchy-dashboard-title')
    labels.append(title)

    const description = new Gtk.Label({
      label: String(node.description || ''),
      xalign: 0,
      ellipsize: Pango.EllipsizeMode.END,
      wrap: true,
      wrap_mode: Pango.WrapMode.WORD_CHAR,
      max_width_chars: 48
    })
    description.add_css_class('omarchy-dashboard-description')
    description.visible = String(node.description || '').length > 0
    labels.append(description)
    content.append(labels)

    const check = new Gtk.Image({ icon_name: 'object-select-symbolic', valign: Gtk.Align.CENTER })
    check.add_css_class('omarchy-dashboard-check')
    check.visible = node.checked === true
    content.append(check)

    const trailing = new Gtk.Image({
      icon_name: node.kind === 'submenu' ? 'go-next-symbolic' : 'go-next-symbolic',
      valign: Gtk.Align.CENTER
    })
    trailing.add_css_class('omarchy-dashboard-trailing')
    trailing.visible = node.kind === 'submenu'
    content.append(trailing)

    this.set_child(content)
    this.content = content

    // A dimmed row is a row the user already has. It stays in the list because
    // the list is a catalogue of what Omarchy can install, and it goes out of
    // the cursor chain and out of the activation path for the same reason the
    // shell steps over it: picking it would run an install of a thing that is
    // already there.
    if (node.disabled === true) {
      content.add_css_class('omarchy-dashboard-row-disabled')
      this.set_sensitive(false)
      this.set_activatable(false)
      this.set_can_focus(false)
    }

    this.connect('activate', () => this._onActivate(this))
  }

  markSelected(selected) {
    if (selected)
      this.content.add_css_class('omarchy-dashboard-row-selected')
    else
      this.content.remove_css_class('omarchy-dashboard-row-selected')
  }
})

// --- the window -------------------------------------------------------------

const DashboardWindow = GObject.registerClass(
class DashboardWindow extends Adw.ApplicationWindow {
  _init(application) {
    super._init({
      application: application,
      title: WINDOW_TITLE,
      default_width: 940,
      default_height: 620,
      width_request: 420,
      height_request: 320
    })

    this.add_css_class('omarchy-dashboard')
    this.applyIcon()

    this.applyTheme()

    this._snapshot = null
    this._byId = new Map()
    this._stack = []
    this._rows = new Map()
    this._selectedId = null
    this._monitors = []
    this._reloadSource = 0
    this._loading = false
    this._queued = false

    this._build()
    this._installActions()
    this._installShortcuts()
    this.watchMenuFiles()

    this.connect('close-request', () => {
      this.stopWatching()
      return false
    })

    this.refresh()
  }

  // --- icon ----------------------------------------------------------------

  // The mark the .desktop entry points at, taken from the tree this app was
  // launched from. Registering the directory rather than loading the file is
  // what GTK 4 offers: Gtk.Window.set_default_icon_from_file is not bound in
  // GJS 1.72, and the icon theme resolves SVG by name, so the same mark then
  // serves the window icon and any icon-name reference beside it.
  applyIcon() {
    const dir = GLib.build_filenamev([ROOT, 'applications', 'icons'])
    if (!GLib.file_test(dir, GLib.FileTest.IS_DIR))
      return

    const theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
    if (theme === null)
      return

    theme.add_search_path(dir)
    if (theme.has_icon('omarchy-dashboard'))
      Gtk.Window.set_default_icon_name('omarchy-dashboard')
  }

  // --- theming -------------------------------------------------------------

  applyTheme() {
    const mode = themeMode()
    if (mode !== null)
      Adw.StyleManager.get_default().color_scheme =
        mode === 'light' ? Adw.ColorScheme.FORCE_LIGHT : Adw.ColorScheme.FORCE_DARK

    // Absent theme, unrendered theme, or a [menu] section with no colours in
    // it: leave the window to libadwaita. A fresh install has never set a
    // theme, and a dashboard that draws itself in a colour nobody chose is
    // worse than one that draws itself in the system's.
    const palette = menuPalette()
    if (!palette)
      return

    const provider = new Gtk.CssProvider()
    provider.load_from_data(themeCss(palette))

    const display = Gdk.Display.get_default()
    if (display === null)
      return

    if (this._provider !== null)
      Gtk.StyleContext.remove_provider_for_display(display, this._provider)
    this._provider = provider
    Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
  }

  // --- widget tree ---------------------------------------------------------

  _build() {
    this.toasts = new Adw.ToastOverlay()

    const outer = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL })
    this.toasts.set_child(outer)
    this.set_content(this.toasts)

    // libadwaita 1.1 has no AdwHeaderBar:title and no
    // AdwHeaderBar:show-window-controls -- both arrived in 1.2. The title is a
    // widget here, and the window controls are the header bar's own, which
    // AdwApplicationWindow wires up for the header bar it finds in its content.
    this.header = new Adw.HeaderBar()
    this.titleLabel = new Gtk.Label({
      label: WINDOW_TITLE,
      ellipsize: Pango.EllipsizeMode.END,
      single_line_mode: true
    })
    this.header.set_title_widget(this.titleLabel)

    this.backButton = new Gtk.Button({
      icon_name: 'go-previous-symbolic',
      tooltip_text: 'Back',
      action_name: 'win.back',
      visible: false
    })
    this.header.pack_start(this.backButton)

    this.headerButton = new Gtk.Button({
      icon_name: 'view-refresh-symbolic',
      tooltip_text: 'Refresh the menu (Ctrl+R)'
    })
    this.headerButton.action_name = 'win.refresh'
    this.header.pack_end(this.headerButton)
    outer.append(this.header)

    // AdwLeaflet's can-navigate and per-child navigate arrived in libadwaita
    // 1.4. What 1.1 has is can-unfold on the child, set below, which is the part
    // that matters: it is what decides whether a narrow window shows one pane
    // or two. Navigation itself is the back button's job, not a swipe's.
    this.leaflet = new Adw.Leaflet()
    outer.append(this.leaflet)

    this._buildSidebar()
    this._buildDetails()

    this.leaflet.append(this.sidebar)
    this.leaflet.append(this.details)
    this.leaflet.set_can_unfold(true)
  }

  _buildSidebar() {
    this.sidebar = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, width_request: 300 })

    this.listBox = new Gtk.ListBox({ selection_mode: Gtk.SelectionMode.SINGLE })
    this.listBox.add_css_class('omarchy-dashboard-list')
    this.listBox.connect('row-selected', (_list, row) => this._onRowSelected(row))
    this.listBox.connect('row-activated', (_list, row) => this._onRowActivated(row))

    this.listScroller = new Gtk.ScrolledWindow({
      hscrollbar_policy: Gtk.PolicyType.NEVER,
      vexpand: true
    })
    this.listScroller.set_child(this.listBox)

    // What the sidebar shows when the level has no rows: a submenu whose
    // `when:` children are all hidden, or one that was never more than a
    // heading. An empty pane reads as a crash; a StatusPage reads as an answer.
    this.emptyList = new Adw.StatusPage({
      icon_name: 'folder-open-symbolic',
      title: 'Nothing here',
      description: 'This menu has no items on this system.'
    })
    this.emptyList.visible = false

    const stack = new Gtk.Stack()
    stack.add_named(this.listScroller, 'list')
    stack.add_named(this.emptyList, 'empty')
    this.sidebarStack = stack
    this.sidebar.append(stack)

    this.errorLabel = new Gtk.Label({
      label: '',
      wrap: true,
      xalign: 0,
      margin_top: 12,
      margin_bottom: 12,
      margin_start: 18,
      margin_end: 18
    })
    this.errorLabel.add_css_class('omarchy-dashboard-body')
    this.errorLabel.visible = false
    this.sidebar.append(this.errorLabel)
  }

  _buildDetails() {
    this.details = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, width_request: 280 })

    this.detailsNothing = new Adw.StatusPage({
      icon_name: 'view-list-symbolic',
      title: 'No row selected',
      description: 'Choose something in the list to see what it does.'
    })

    const scroller = new Gtk.ScrolledWindow({ vexpand: true })
    scroller.set_child(this.detailsNothing)

    this.detailBox = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 8 })
    this.detailBox.margin_top = 18
    this.detailBox.margin_bottom = 18
    this.detailBox.margin_start = 18
    this.detailBox.margin_end = 18

    this.detailIcon = new Gtk.Label({ xalign: 0 })
    this.detailIcon.add_css_class('omarchy-dashboard-icon')
    this.detailBox.append(this.detailIcon)

    this.detailTitle = new Gtk.Label({ xalign: 0, wrap: true })
    this.detailTitle.add_css_class('omarchy-dashboard-heading')
    this.detailBox.append(this.detailTitle)

    this.detailDescription = new Gtk.Label({ xalign: 0, wrap: true, max_width_chars: 44 })
    this.detailDescription.add_css_class('omarchy-dashboard-body')
    this.detailBox.append(this.detailDescription)

    const rule = new Gtk.Box({ height_request: 1, margin_top: 8, margin_bottom: 8 })
    rule.add_css_class('omarchy-dashboard-border')
    this.detailBox.append(rule)

    this.detailPath = new Gtk.Label({ xalign: 0, wrap: true, selectable: true })
    this.detailPath.add_css_class('omarchy-dashboard-mono')
    this.detailBox.append(this.detailPath)

    this.detailAction = new Gtk.Label({ xalign: 0, wrap: true, selectable: true })
    this.detailAction.add_css_class('omarchy-dashboard-mono')
    this.detailBox.append(this.detailAction)

    const detailScroller = new Gtk.ScrolledWindow({ vexpand: true })
    detailScroller.set_child(this.detailBox)
    this.detailsStack = new Gtk.Stack()
    this.detailsStack.add_named(scroller, 'empty')
    this.detailsStack.add_named(detailScroller, 'detail')

    this.details.append(this.detailsStack)
  }

  _installActions() {
    const back = new Gio.SimpleAction({ name: 'back' })
    back.connect('activate', () => this.goBack())
    this.add_action(back)

    const refresh = new Gio.SimpleAction({ name: 'refresh' })
    refresh.connect('activate', () => this.refresh())
    this.add_action(refresh)
  }

  // Ctrl+R re-runs the snapshot and Backspace goes back, so the two things the
  // terminal front end does with `r` and its left arrow are one keystroke away
  // here too. Gtk.Application.set_accels_for_action is not bound in GJS 1.72,
  // so the GTK 4 way of saying this -- a shortcut controller on the window, in
  // the same action namespace the buttons already use -- is also the only one.
  _installShortcuts() {
    const controller = new Gtk.ShortcutController({ scope: Gtk.ShortcutScope.GLOBAL })

    // GtkShortcut has no set_action_name() in GJS 1.72, and action-name is not
    // constructible either; it is assignable, which is enough.
    for (const [accelerator, action] of [['Ctrl+r', 'win.refresh'], ['BackSpace', 'win.back']]) {
      const shortcut = new Gtk.Shortcut({ trigger: Gtk.ShortcutTrigger.parse_string(accelerator) })
      shortcut.action_name = action
      controller.add_shortcut(shortcut)
    }

    this.add_controller(controller)
  }

  // --- watching the menu files --------------------------------------------

  watchMenuFiles() {
    for (const path of menuFiles()) {
      const file = Gio.File.new_for_path(path)
      let monitor = null

      try {
        monitor = file.monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null)
      } catch (e) {
        // The user's overlay does not exist on a machine that has never been
        // given one, and that is the normal case rather than a fault. Watch the
        // directory that would hold it, so creating the file still reloads.
        try {
          monitor = file.get_parent().monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null)
        } catch (e2) {
          continue
        }
      }

      const isMine = (changed, other) => {
        if (other !== null)
          return GLib.path_get_basename(other.get_path()) === GLib.path_get_basename(path)
        return GLib.path_get_basename(changed.get_path()) === GLib.path_get_basename(path)
      }

      monitor.connect('changed', (_monitor, changed, other, eventType) => {
        if (eventType === Gio.FileMonitorEvent.CHANGES_DONE_HINT ||
            eventType === Gio.FileMonitorEvent.CREATED ||
            eventType === Gio.FileMonitorEvent.MOVED_IN ||
            eventType === Gio.FileMonitorEvent.DELETED ||
            eventType === Gio.FileMonitorEvent.ATTRIBUTE_CHANGED) {
          if (isMine(changed, other))
            this.queueReload()
        }
      })

      this._monitors.push(monitor)
    }
  }

  stopWatching() {
    for (const monitor of this._monitors)
      monitor.cancel()
    this._monitors = []

    if (this._reloadSource) {
      GLib.source_remove(this._reloadSource)
      this._reloadSource = 0
    }
  }

  // An editor writes a file in several syscalls, and the monitor reports each
  // one. Re-running the snapshot per event would spawn a process per write; one
  // reload after the dust settles is the same result and the right cost.
  queueReload() {
    if (this._reloadSource)
      GLib.source_remove(this._reloadSource)

    this._reloadSource = GLib.timeout_add(GLib.PRIORITY_DEFAULT, REFRESH_DEBOUNCE_MS, () => {
      this._reloadSource = 0
      this.refresh()
      return GLib.SOURCE_REMOVE
    })
  }

  // --- loading -------------------------------------------------------------

  refresh() {
    if (this._loading) {
      this._queued = true
      return
    }

    this._loading = true
    this.errorLabel.visible = false
    this.listBox.sensitive = false
    this.headerButton.sensitive = false

    loadSnapshot(result => {
      this._loading = false
      this.listBox.sensitive = true
      this.headerButton.sensitive = true

      if (!result.ok) {
        this.errorLabel.label = 'Could not load the menu: ' + result.message
        this.errorLabel.visible = true
        if (this._snapshot === null) {
          this._renderRows([], null)
          this.setTitle()
        }
      } else {
        this._snapshot = result.snapshot
        this._reindex()
        this._render()
      }

      if (this._queued) {
        this._queued = false
        this.refresh()
      }
    })
  }

  _reindex() {
    this._byId = new Map()
    const index = node => {
      if (!node || !node.id || this._byId.has(node.id))
        return
      this._byId.set(node.id, node)
      for (const child of node.children || [])
        index(child)
    }
    index(this._snapshot.tree)
  }

  currentNode() {
    if (this._stack.length === 0)
      return this._snapshot ? this._snapshot.tree : null
    return this._byId.get(this._stack[this._stack.length - 1]) || null
  }

  currentRows() {
    const node = this.currentNode()
    if (!node)
      return []
    return node.children || []
  }

  // Every submenu opens, including one with nothing in it. A submenu whose
  // children are all hidden by their guards -- Style > Font on a machine with
  // no fonts provider resolved is the shipped example -- is a place the user
  // can legitimately go and find out it is empty. Refusing to open it would
  // leave the keypress doing nothing at all, and an empty pane with nothing in
  // it is the failure this avoids: descending shows the sidebar's StatusPage
  // instead, which is an answer.
  isSubmenu(node) {
    return node !== null && node !== undefined && String(node.kind || '') === 'submenu'
  }

  // A link runs whatever its target runs, so a user never has to know whether a
  // row happens to be spelled as a link. This is TuiModel.actionFor, restated
  // rather than reinvented.
  actionFor(node) {
    if (!node)
      return null
    if (node.action)
      return String(node.action)

    if (node.target) {
      const target = this._byId.get(node.target)
      if (target && target.action)
        return String(target.action)
      return null
    }

    return null
  }

  // --- navigation ----------------------------------------------------------

  render() {
    this._render()
  }

  _render() {
    // A refresh can remove a level: an extension that hid the submenu the user
    // was inside must not leave them reading rows from a place they navigated
    // out of. Drop to the deepest level the new tree still has.
    while (this._stack.length > 0 && !this._byId.has(this._stack[this._stack.length - 1]))
      this._stack.pop()

    this._renderRows(this.currentRows(), this._selectedId)
    this.setTitle()
  }

  _renderRows(rows, keepId) {
    let child = this.listBox.get_first_child()
    while (child !== null) {
      const next = child.get_next_sibling()
      this.listBox.remove(child)
      child = next
    }

    this._rows = new Map()
    let selected = null

    for (const node of rows) {
      const row = new ListRow(node, r => this._onRowActivated(r))
      this._rows.set(node.id, row)
      this.listBox.append(row)
      if (node.id === keepId)
        selected = row
    }

    if (selected === null && rows.length > 0)
      selected = this.listBox.get_row_at_index(0)

    this.emptyList.visible = rows.length === 0
    this.listScroller.visible = rows.length > 0
    this.sidebarStack.set_visible_child_name(rows.length === 0 ? 'empty' : 'list')

    if (selected !== null && selected.get_parent() !== null)
      this.listBox.select_row(selected)

    // Arrow keys move the selection, and a GtkListBox only does that while it
    // holds focus. A list nobody can drive from the keyboard is a list that
    // needs a mouse, and the terminal front end the user came from does not.
    if (rows.length > 0 && !this.listBox.has_focus)
      this.listBox.grab_focus()

    this._selectedId = selected !== null ? selected.node.id : null
    this.updateDetails()
  }

  setTitle() {
    const node = this.currentNode()
    let title = WINDOW_TITLE

    if (node && this._stack.length > 0)
      title = String(node.title || node.label || node.id || WINDOW_TITLE)

    this.titleLabel.label = title
    this.backButton.visible = this._stack.length > 0
  }

  goBack() {
    if (this._stack.length === 0)
      return

    this._stack.pop()
    this._selectedId = null
    this._render()
    this.updateDetails()
  }

  descend(node) {
    this._stack.push(node.id)
    this._selectedId = null
    this._render()
  }

  // --- selection and activation -------------------------------------------

  _onRowSelected(row) {
    for (const other of this._rows.values())
      other.markSelected(other === row)

    this._selectedId = row !== null ? row.node.id : null
    this.updateDetails()
  }

  _onRowActivated(row) {
    if (row === null || row.sensitive === false)
      return

    const node = row.node

    if (this.isSubmenu(node)) {
      this.descend(node)
      return
    }

    if (node.disabled === true) {
      this.toast(String(node.label || node.id) + ' is already installed')
      return
    }

    const action = this.actionFor(node)

    if (!action) {
      this.toast('Nothing to run for ' + String(node.label || node.id))
      return
    }

    this.run(node, action)
  }

  updateDetails() {
    const row = this._selectedId === null ? null : this._rows.get(this._selectedId)
    const node = row === null ? null : row.node

    if (node === null) {
      this.detailsStack.set_visible_child_name('empty')
      return
    }

    this.detailIcon.label = nodeGlyph(node)
    this.detailIcon.visible = String(node.icon || '').length > 0
    this.detailTitle.label = String(node.label || node.id)
    this.detailDescription.label = String(node.description || '')
    this.detailDescription.visible = String(node.description || '').length > 0
    this.detailPath.label = String(node.path || node.id)

    if (node.disabled === true) {
      this.detailAction.label = 'Already installed. This row cannot be run.'
    } else if (this.isSubmenu(node)) {
      this.detailAction.label = 'Opens ' + String(node.title || node.label || node.id)
    } else {
      const action = this.actionFor(node)
      this.detailAction.label = action ? 'Runs: ' + action : 'Nothing to run for this row'
    }

    this.detailsStack.set_visible_child_name('detail')
  }

  // --- running -------------------------------------------------------------

  run(node, action) {
    // Hold the window open at the end so the output is readable; a terminal
    // that vanishes on exit is a terminal nobody saw anything in.
    const script = [
      action,
      'status=$?',
      'printf \'\\n[omarchy] %s exited with status %d. Press Enter to close.\\n\' ' +
        quoteForShell(String(node.label || node.id)) + ' "$status"',
      'read -r _ || true',
      'exit $status'
    ].join('\n')

    const argv = terminalArgv(['bash', '-lc', script])

    if (argv === null) {
      this.toast('No terminal emulator found to run ' + String(node.label || node.id) + ' in')
      return
    }

    try {
      // Reaped so the terminal does not sit in the process table as a zombie
      // for as long as the dashboard is open; nothing reads its status.
      const process = launcherFor().spawnv(argv)
      process.wait_async(null, (waited, result) => {
        try {
          waited.wait_finish(result)
        } catch (e) {
          // A terminal that vanished before it exited is not the dashboard's
          // problem; the child is gone either way.
        }
      })
    } catch (e) {
      this.toast('Could not open a terminal: ' + e.message)
      return
    }

    this.toast('Running ' + String(node.label || node.id) + ' in a terminal')
  }

  toast(message) {
    this.toasts.add_toast(new Adw.Toast({ title: String(message), timeout: 4 }))
  }
})

// --- the application --------------------------------------------------------

const DashboardApplication = GObject.registerClass(
class DashboardApplication extends Adw.Application {
  _init() {
    super._init({ application_id: APP_ID, flags: Gio.ApplicationFlags.FLAGS_NONE })

    this.connect('activate', () => {
      const existing = this.get_active_window()
      if (existing !== null) {
        existing.present()
        return
      }

      const window = new DashboardWindow(this)
      this.connect('shutdown', () => window.stopWatching())
      window.present()
    })
  }
})

// Only the program name goes to GApplication.run(). `--route=` is this file's
// own option, not a GApplication one, and handing an unrecognised option to
// run() is how an app ends up refusing to start over a flag the user typed for
// the menu.
const programName = ARGV.length > 0 ? ARGV[0] : 'omarchy-dashboard'

// `gjs -m omarchy-dashboard.js --check` parses this whole file -- the module
// loader parses before it evaluates -- and then imports every typelib the window
// needs, which is the same question `omarchy-dashboard-app --available` asks
// without a window. It is a real start-up check, not a stub, and it is the only
// way to prove the app loads on a machine that has the typelibs but no display.
if (ARGV.includes('--check')) {
  Gtk.init()
  print('ok')
} else {
  new DashboardApplication().run([programName])
}
