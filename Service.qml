import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Owns the three-finger swipe-up that summons the overview. Hyprland 0.56 has
// no way to bind a touchpad swipe without editing the compositor config, but
// its Lua state is scriptable over IPC, so the service registers the gesture
// at startup instead of asking the user to paste a snippet into input.lua.
//
// hl.gesture cannot be unregistered, only re-declared, so registration is
// guarded by a Lua global: a shell restart finds the guard set and does
// nothing. A config reload rebuilds Hyprland's Lua state and drops runtime
// gestures (probed: after `hyprctl reload` a global set through `hyprctl repl`
// reads back nil), so `configreloaded` registers again from scratch.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Set for a registration that must not trust the guard: after a config
  // reload the previous registration is gone even if the guard survived.
  property bool reregister: false

  readonly property string manifestId: manifest && manifest.id ? manifest.id : "io.github.terrifiedbug.omaspaces"

  // Services are not handed their inline settings either; read shell.json the
  // same way the overlay does.
  readonly property var settings: {
    var text = shellConfig.text()
    if (!text) return ({})
    var config = ({})
    try { config = JSON.parse(text) } catch (e) { return ({}) }
    var entries = config && config.plugins && config.plugins.length !== undefined ? config.plugins : []
    for (var i = 0; i < entries.length; i++) if (entries[i] && entries[i].id === root.manifestId) return entries[i]
    return ({})
  }

  readonly property bool gestureEnabled: setting("gesture", true) !== false

  readonly property string gestureLua:
    "if not _G.__omaspaces_gesture then " +
    "_G.__omaspaces_gesture = true " +
    "hl.gesture({ fingers = 3, direction = \"up\", action = function() " +
    "hl.dispatch(hl.dsp.exec_raw([[omarchy-shell shell toggle " + manifestId + " '{}']])) end }) " +
    "return \"registered\" end return \"present\""

  function setting(name, fallback) {
    var value = settings[name]
    return value === undefined || value === null ? fallback : value
  }

  function registerGesture() {
    if (!gestureEnabled) return
    // hl.gesture only exists when Hyprland runs the Lua config; on the legacy
    // hyprland.conf the user binds the summon themselves (README).
    if (Hyprland.usingLua !== true) {
      console.warn("omaspaces: Hyprland is not running the Lua config; swipe-up not registered")
      return
    }
    if (registerProc.running) return
    registerProc.running = true
  }

  Component.onCompleted: registerGesture()

  // Flipping `gesture` back on in shell.json takes effect without a restart.
  onGestureEnabledChanged: if (gestureEnabled) registerGesture()

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }

  Process {
    id: registerProc
    command: ["hyprctl", "repl", (root.reregister ? "_G.__omaspaces_gesture = nil " : "") + root.gestureLua]

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: {
        var out = String(text || "").trim()
        root.reregister = false
        if (out !== "registered" && out !== "present") console.warn("omaspaces: gesture registration failed:", out)
      }
    }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name === "configreloaded") {
        root.reregister = true
        root.registerGesture()
      }
    }
  }

  IpcHandler {
    target: "omaspaces"

    function ping(): string {
      return "ok"
    }

    function status(): string {
      return JSON.stringify({ gesture: root.gestureEnabled, lua: Hyprland.usingLua === true })
    }

    function registerGesture(): string {
      root.reregister = true
      root.registerGesture()
      return "ok"
    }
  }
}
