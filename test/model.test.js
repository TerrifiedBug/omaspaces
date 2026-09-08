const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

// Shapes copied from live `hyprctl monitors -j` / `clients -j` on a 2880x1800
// @ scale 2 panel (logical 1440x900): every tiled window reports the same
// at/size, `grouped` lists tab order and has length 1 when ungrouped.
const MONITOR = {
  id: 0,
  name: "eDP-1",
  x: 0,
  y: 0,
  width: 2880,
  height: 1800,
  scale: 2,
  focused: true,
  activeWorkspace: { id: 2, name: "2" }
}

const GROUP = ["0xA", "0xB"]

function client(overrides) {
  return Object.assign({
    address: "0xA",
    class: "google-chrome",
    title: "Tab",
    workspace: { id: 1, name: "1" },
    monitor: 0,
    at: [12, 66],
    size: [1416, 822],
    mapped: true,
    hidden: false,
    visible: true,
    grouped: ["0xA"],
    focusHistoryID: 0
  }, overrides)
}

// Client order deliberately puts the background tab first so the group's
// member order can only come from `grouped`.
const CLIENTS = [
  client({ address: "0xB", title: "Background tab", visible: false, grouped: GROUP, focusHistoryID: 2 }),
  client({ address: "0xA", title: "Front tab", visible: true, grouped: GROUP, focusHistoryID: 1 }),
  client({ address: "0xC", title: "Terminal", class: "com.mitchellh.ghostty", workspace: { id: 2, name: "2" }, grouped: ["0xC"] }),
  client({ address: "0xD", title: "Notes", workspace: { id: 7, name: "7" }, grouped: ["0xD"] })
]

const BOARD = Model.buildBoard([MONITOR], CLIENTS, 5)

test("asList unwraps a QVariantList-shaped value and tolerates nothing", () => {
  assert.deepEqual(Model.asList({ length: 2, 0: "a", 1: "b" }), ["a", "b"])
  assert.deepEqual(Model.asList(undefined), [])
})

test("buildBoard lists 1..count plus any populated higher workspace", () => {
  assert.deepEqual(BOARD[0].workspaces.map(ws => ws.id), [1, 2, 3, 4, 5, 7])
})

test("buildBoard groups the tabs in `grouped` order, not client order", () => {
  const ws1 = BOARD[0].workspaces[0]
  assert.equal(ws1.windows.length, 2)
  assert.equal(ws1.groups.length, 1)
  assert.deepEqual(ws1.groups[0].members.map(w => w.address), ["0xA", "0xB"])
  assert.equal(ws1.groups[0].members[0].front, true)
  assert.equal(ws1.groups[0].members[1].front, false)
  assert.equal(ws1.groups[0].members[1].groupSize, 2)
})

test("buildBoard marks the monitor's active workspace and leaves empties empty", () => {
  assert.equal(BOARD[0].workspaces[1].current, true)
  assert.equal(BOARD[0].workspaces[0].current, false)
  assert.equal(BOARD[0].workspaces[2].windows.length, 0)
  assert.equal(BOARD[0].workspaces[2].groups.length, 0)
})

test("normalizedRect maps window geometry into the monitor's logical frame", () => {
  const rect = BOARD[0].workspaces[0].windows[0].rect
  assert.ok(Math.abs(rect.x - 12 / 1440) < 1e-9)
  assert.ok(Math.abs(rect.y - 66 / 900) < 1e-9)
  assert.ok(Math.abs(rect.w - 1416 / 1440) < 1e-9)
  assert.ok(Math.abs(rect.h - 822 / 900) < 1e-9)
})

test("groupKey is member-order independent and blank for a lone window", () => {
  assert.equal(Model.groupKey(["0xB", "0xA"]), Model.groupKey(["0xA", "0xB"]))
  assert.equal(Model.groupKey(["0xC"]), "")
})

test("isBoardWindow rejects unmapped, hidden, and special-workspace clients", () => {
  assert.equal(Model.isBoardWindow(client({})), true)
  assert.equal(Model.isBoardWindow(client({ mapped: false })), false)
  assert.equal(Model.isBoardWindow(client({ hidden: true })), false)
  assert.equal(Model.isBoardWindow(client({ workspace: { id: -99, name: "special" } })), false)
})

test("initialSelection starts on the focused monitor's current workspace", () => {
  assert.deepEqual(Model.initialSelection(BOARD), { mon: 0, ws: 1, group: -1, member: -1 })
})

test("moveSelection wraps along the tile row", () => {
  const last = { mon: 0, ws: 5, group: -1, member: -1 }
  assert.equal(Model.moveSelection(BOARD, last, "right").ws, 0)
  assert.equal(Model.moveSelection(BOARD, { mon: 0, ws: 0, group: -1, member: -1 }, "left").ws, 5)
})

test("moveSelection enters a column at the front tab and returns to the tile", () => {
  const tile = { mon: 0, ws: 0, group: -1, member: -1 }
  const entered = Model.moveSelection(BOARD, tile, "down")
  assert.deepEqual(entered, { mon: 0, ws: 0, group: 0, member: 0 })
  assert.deepEqual(Model.moveSelection(BOARD, entered, "up"), tile)
})

test("moveSelection is a no-op on a groupless tile and at the last tab", () => {
  const groupless = { mon: 0, ws: 1, group: -1, member: -1 }
  assert.deepEqual(Model.moveSelection(BOARD, groupless, "down"), groupless)
  const lastTab = { mon: 0, ws: 0, group: 0, member: 1 }
  assert.deepEqual(Model.moveSelection(BOARD, lastTab, "down"), lastTab)
})

test("digitTarget picks tiles on the row and tabs inside a column", () => {
  const tile = { mon: 0, ws: 0, group: -1, member: -1 }
  assert.equal(Model.digitTarget(BOARD, tile, 9), null)
  assert.deepEqual(Model.digitTarget(BOARD, tile, 2), { kind: "workspace", id: 2 })
  const inColumn = { mon: 0, ws: 0, group: 0, member: 0 }
  assert.deepEqual(Model.digitTarget(BOARD, inColumn, 2), { kind: "window", address: "0xB" })
})

test("activationTarget resolves the tile or the selected tab", () => {
  assert.deepEqual(Model.activationTarget(BOARD, { mon: 0, ws: 3, group: -1, member: -1 }), { kind: "workspace", id: 4 })
  assert.deepEqual(Model.activationTarget(BOARD, { mon: 0, ws: 0, group: 0, member: 1 }), { kind: "window", address: "0xB" })
})

test("normalizeWorkspaceCount falls back and clamps to Hyprland's ten", () => {
  assert.equal(Model.normalizeWorkspaceCount("abc", 5), 5)
  assert.equal(Model.normalizeWorkspaceCount(0), 1)
  assert.equal(Model.normalizeWorkspaceCount(99), 10)
})
