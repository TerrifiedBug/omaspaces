// Pure board model for the overview: turns `hyprctl clients -j` /
// `monitors -j` shaped objects into monitor -> workspace -> group structure,
// and owns the keyboard cursor. Qt-free so node can test it
// (test/model.test.js); Overview.qml only draws what these functions return.

var DEFAULT_WORKSPACES = 5
var MAX_WORKSPACES = 10

// The bar shows five workspaces, Hyprland binds ten; anything outside that
// range is a typo in shell.json rather than an intent worth honouring.
function normalizeWorkspaceCount(value, fallback) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return fallback === undefined ? DEFAULT_WORKSPACES : fallback
  return Math.max(1, Math.min(MAX_WORKSPACES, n))
}

// QVariantLists from Quickshell fail Array.isArray; duck-type on length.
function asList(value) {
  if (!value || value.length === undefined) return []
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

// A window is drawable when it is mapped, not hidden, on a regular workspace.
function isBoardWindow(client) {
  if (!client || client.mapped === false || client.hidden === true) return false
  var ws = client.workspace && client.workspace.id !== undefined ? Number(client.workspace.id) : NaN
  return isFinite(ws) && ws > 0
}

// Position/size in a 0..1 frame of the monitor the window sits on.
function normalizedRect(client, monitor) {
  var at = asList(client.at), size = asList(client.size)
  var mw = monitor.width / monitor.scale, mh = monitor.height / monitor.scale
  return {
    x: (Number(at[0]) - monitor.x) / mw,
    y: (Number(at[1]) - monitor.y) / mh,
    w: Number(size[0]) / mw,
    h: Number(size[1]) / mh
  }
}

// Groups are identified by their sorted member addresses so every member
// yields the same key regardless of which member we start from.
function groupKey(grouped) {
  var addresses = asList(grouped).map(String)
  if (addresses.length < 2) return ""
  return addresses.slice().sort().join("|")
}

// board = [{ monitor: {id,name,x,y,width,height,scale,focused,activeWorkspaceId},
//            workspaces: [{ id, current, windows: [{address,title,appId,rect,front,groupKey,groupSize,focusHistoryID}],
//                           groups: [{ key, members: [window…] /* tab order */ }] }] }]
// Workspace ids 1..count always appear (empty ones included, in order); any
// higher id that has a window is appended after them.
function buildBoard(monitors, clients, count) {
  var mons = asList(monitors).filter(function(m) { return m && m.id !== undefined })
  var wins = asList(clients).filter(isBoardWindow)
  return mons.map(function(mon) {
    var monId = Number(mon.id)
    var activeWs = mon.activeWorkspace && mon.activeWorkspace.id !== undefined ? Number(mon.activeWorkspace.id) : -1
    var byWs = {}
    wins.filter(function(c) { return Number(c.monitor) === monId }).forEach(function(c) {
      var ws = Number(c.workspace.id)
      if (!byWs[ws]) byWs[ws] = []
      byWs[ws].push(c)
    })
    var ids = []
    for (var i = 1; i <= count; i++) ids.push(i)
    Object.keys(byWs).map(Number).filter(function(id) { return id > count }).sort(function(a, b) { return a - b })
      .forEach(function(id) { ids.push(id) })
    var workspaces = ids.map(function(id) {
      var clientsHere = byWs[id] || []
      var windows = clientsHere.map(function(c) {
        var grouped = asList(c.grouped)
        return {
          address: String(c.address),
          title: String(c.title || ""),
          appId: String(c.class || c.initialClass || ""),
          rect: normalizedRect(c, mon),
          front: c.visible === true,
          groupKey: groupKey(grouped),
          groupSize: grouped.length,
          focusHistoryID: Number(c.focusHistoryID)
        }
      })
      var groups = [], seen = {}
      clientsHere.forEach(function(c) {
        var key = groupKey(c.grouped)
        if (!key || seen[key]) return
        seen[key] = true
        var order = asList(c.grouped).map(String)
        var members = order.map(function(addr) {
          for (var w = 0; w < windows.length; w++) if (windows[w].address === addr) return windows[w]
          return null
        }).filter(function(w) { return w !== null })
        groups.push({ key: key, members: members })
      })
      // Left-to-right by the group's front tab so columns match on-screen order.
      groups.sort(function(a, b) { return a.members[0].rect.x - b.members[0].rect.x })
      return { id: id, current: id === activeWs, windows: windows, groups: groups }
    })
    return {
      monitor: {
        id: monId,
        name: String(mon.name || ""),
        x: mon.x,
        y: mon.y,
        width: mon.width,
        height: mon.height,
        scale: mon.scale,
        focused: mon.focused === true,
        activeWorkspaceId: activeWs
      },
      workspaces: workspaces
    }
  })
}

// Keyboard cursor. group === -1 means the workspace tile itself is selected;
// otherwise (group, member) index into that workspace's groups.
function initialSelection(board) {
  for (var m = 0; m < board.length; m++) {
    if (!board[m].monitor.focused) continue
    for (var w = 0; w < board[m].workspaces.length; w++)
      if (board[m].workspaces[w].current) return { mon: m, ws: w, group: -1, member: -1 }
  }
  return { mon: 0, ws: 0, group: -1, member: -1 }
}

// The front tab is the one Hyprland is showing, so entering a column lands on
// what the workspace tile above it already displays.
function frontIndex(group) {
  for (var i = 0; i < group.members.length; i++) if (group.members[i].front) return i
  return 0
}

// Left/Right walk tiles (wrapping within the monitor row); Down from a tile
// enters its first group's front tab, Down/Up walk members, Up from the first
// member returns to the tile; Left/Right inside a column hop between that
// workspace's groups when there are several. Unknown keys return the input.
function moveSelection(board, sel, key) {
  var row = board[sel.mon], ws = row.workspaces[sel.ws], count = row.workspaces.length
  if (sel.group === -1) {
    if (key === "left") return { mon: sel.mon, ws: (sel.ws + count - 1) % count, group: -1, member: -1 }
    if (key === "right") return { mon: sel.mon, ws: (sel.ws + 1) % count, group: -1, member: -1 }
    if (key === "down" && ws.groups.length > 0) return { mon: sel.mon, ws: sel.ws, group: 0, member: frontIndex(ws.groups[0]) }
    return sel
  }
  var group = ws.groups[sel.group]
  if (key === "up")
    return sel.member === 0
      ? { mon: sel.mon, ws: sel.ws, group: -1, member: -1 }
      : { mon: sel.mon, ws: sel.ws, group: sel.group, member: sel.member - 1 }
  if (key === "down") return { mon: sel.mon, ws: sel.ws, group: sel.group, member: Math.min(group.members.length - 1, sel.member + 1) }
  if (key === "left" && sel.group > 0) return { mon: sel.mon, ws: sel.ws, group: sel.group - 1, member: 0 }
  if (key === "right" && sel.group < ws.groups.length - 1) return { mon: sel.mon, ws: sel.ws, group: sel.group + 1, member: 0 }
  return sel
}

// Digit keys: on a tile row, 1..9 jump to the Nth workspace tile; inside a
// column they pick the Nth tab. Returns null when N is out of range.
function digitTarget(board, sel, digit) {
  var row = board[sel.mon], ws = row.workspaces[sel.ws]
  if (sel.group === -1) {
    var tile = row.workspaces[digit - 1]
    return tile ? { kind: "workspace", id: tile.id } : null
  }
  var member = ws.groups[sel.group].members[digit - 1]
  return member ? { kind: "window", address: member.address } : null
}

// What Enter/click on the current selection should do.
function activationTarget(board, sel) {
  var ws = board[sel.mon].workspaces[sel.ws]
  if (sel.group === -1) return { kind: "workspace", id: ws.id }
  return { kind: "window", address: ws.groups[sel.group].members[sel.member].address }
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_WORKSPACES: DEFAULT_WORKSPACES,
    MAX_WORKSPACES: MAX_WORKSPACES,
    normalizeWorkspaceCount: normalizeWorkspaceCount,
    asList: asList,
    isBoardWindow: isBoardWindow,
    normalizedRect: normalizedRect,
    groupKey: groupKey,
    buildBoard: buildBoard,
    initialSelection: initialSelection,
    frontIndex: frontIndex,
    moveSelection: moveSelection,
    digitTarget: digitTarget,
    activationTarget: activationTarget
  }
}
