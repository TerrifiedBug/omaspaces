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

  // Confirmed once hyprctl answers "registered" or "present". Until then the
  // retry below keeps trying, because a `hyprctl repl` issued while Hyprland
  // is still coming up can fail and nothing else would notice.
  property bool registered: false
  property int attempts: 0

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

  // hl.gesture only exists when Hyprland runs the Lua config. This has to be
  // a bound property, not a read inside registerGesture(): the flag flips
  // when the version query answers, a beat after the service is constructed,
  // and nothing observes that flip unless something is bound to it. Reading
  // it imperatively meant a shell started from a clean Lua state registered
  // nothing at all, which is how the swipe came back dead after a reboot.
  readonly property bool luaReady: Hyprland.usingLua === true

  // The guard is set after hl.gesture returns, never before: setting it first
  // means a call that throws still leaves the guard behind, and every later
  // attempt then reports "present" for a gesture that was never registered.
  readonly property string gestureLua:
    "if not _G.__omaspaces_gesture then " +
    "hl.gesture({ fingers = 3, direction = \"up\", action = function() " +
    "hl.dispatch(hl.dsp.exec_raw([[omarchy-shell shell toggle " + manifestId + " '{}']])) end }) " +
    "_G.__omaspaces_gesture = true " +
    "return \"registered\" end return \"present\""

  function setting(name, fallback) {
    var value = settings[name]
    return value === undefined || value === null ? fallback : value
  }

  function registerGesture() {
    if (!gestureEnabled) return
    // Only a legacy hyprland.conf leaves this false for good, and there the
    // user binds the summon themselves (README).
    if (!luaReady) return
    if (registerProc.running) return
    registerProc.running = true
  }

  Component.onCompleted: registerGesture()

  // Flipping `gesture` back on in shell.json takes effect without a restart.
  onGestureEnabledChanged: if (gestureEnabled) registerGesture()

  onLuaReadyChanged: registerGesture()

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }

  Timer {
    id: retryTimer
    interval: 2500
    repeat: true
    running: root.gestureEnabled && root.luaReady && !root.registered && root.attempts < 8

    onTriggered: root.registerGesture()
  }

  // usingLua only ever flips false -> true, so a legacy hyprland.conf leaves
  // the startup path silent. Say it once rather than letting the user wonder
  // why the swipe does nothing.
  Timer {
    id: legacyNotice
    interval: 3000
    running: root.gestureEnabled

    onTriggered: if (!root.luaReady) console.warn("omaspaces: Hyprland is not running the Lua config; swipe-up not registered, bind it yourself (README)")
  }

  Process {
    id: registerProc
    command: ["hyprctl", "repl", (root.reregister ? "_G.__omaspaces_gesture = nil " : "") + root.gestureLua]

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: {
        var out = String(text || "").trim()
        root.reregister = false
        root.attempts = root.attempts + 1
        root.registered = out === "registered" || out === "present"
        if (!root.registered) console.warn("omaspaces: gesture registration failed:", out)
      }
    }
  }

  Connections {
    target: Hyprland

    // A config reload rebuilds Hyprland's Lua state and drops the gesture
    // along with the guard, so the previous confirmation no longer holds.
    function onRawEvent(event) {
      if (event.name !== "configreloaded") return
      root.reregister = true
      root.registered = false
      root.attempts = 0
      root.registerGesture()
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

    // Repair call for a swipe that never got registered — it does not force
    // past the guard, because hl.gesture cannot be unregistered and a second
    // registration would toggle the board twice per swipe. A registration
    // that really is stale is cleared by `hyprctl reload`, which wipes the
    // guard along with it and lets the configreloaded path register cleanly.
    function registerGesture(): string {
      root.registerGesture()
      return "ok"
    }
  }
}
