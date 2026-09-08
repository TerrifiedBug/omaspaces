import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Mission-Control-style board: the workspaces of every monitor as live tiles
// in a row, and under any workspace that holds a Hyprland group, that group's
// tabs stacked vertically with their own live thumbnails. Hyprland's groupbar
// shows tab titles in hardcoded white and nothing else, so the vertical
// column is the whole point of the plugin; it is the only accent-tinted
// surface on the board so a group can never be mistaken for a workspace.
//
// The board is a snapshot, not a binding: Hyprland.refreshToplevels() is
// asynchronous and blanks every lastIpcObject until the reply lands, so a
// binding over Hyprland.toplevels would render an empty board for half a
// second on every open. settleTimer polls the objects instead and swaps the
// whole board in once they are all populated.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  // board / toplevelByAddress are swapped together: the delegates index the
  // map by the address the board carries.
  property var board: []
  property var toplevelByAddress: ({})
  property var selection: null
  property int settleTicks: 0

  readonly property string manifestId: manifest && manifest.id ? manifest.id : "io.github.terrifiedbug.omaspaces"

  // Overlays are not handed their inline settings (shell.qml only assigns
  // omarchyPath/shell/manifest/registries/service), so read the plugins[]
  // entry out of shell.json directly. watchChanges keeps a live edit honest.
  readonly property var settings: {
    var text = shellConfig.text()
    if (!text) return ({})
    var config = ({})
    try { config = JSON.parse(text) } catch (e) { return ({}) }
    var entries = config && config.plugins && config.plugins.length !== undefined ? config.plugins : []
    for (var i = 0; i < entries.length; i++) if (entries[i] && entries[i].id === root.manifestId) return entries[i]
    return ({})
  }

  readonly property int workspaceCount: Model.normalizeWorkspaceCount(setting("workspaces", Model.DEFAULT_WORKSPACES), Model.DEFAULT_WORKSPACES)

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color faintForeground: Qt.darker(Color.menu.text, 1.8)
  readonly property color surfaceBorder: Color.menu.border
  readonly property string fontFamily: Style.font.menuFamily
  // Nerd Font glyphs come from the bar family; OMARCHY_MENU_FONT may point
  // menuFamily at a text font with no glyph coverage.
  readonly property string glyphFamily: Style.font.family
  readonly property int boardMargin: Style.spacing.panelPadding * 2
  readonly property int tileSpacing: Style.space(16)
  readonly property int columnSpacing: Style.space(8)
  readonly property int thumbRadius: Style.space(4)

  readonly property int windowCount: {
    var total = 0
    for (var m = 0; m < board.length; m++)
      for (var w = 0; w < board[m].workspaces.length; w++) total += board[m].workspaces[w].windows.length
    return total
  }

  readonly property int groupCount: {
    var total = 0
    for (var m = 0; m < board.length; m++)
      for (var w = 0; w < board[m].workspaces.length; w++) total += board[m].workspaces[w].groups.length
    return total
  }

  readonly property string focusedMonitorName: {
    for (var m = 0; m < board.length; m++) if (board[m].monitor.focused) return board[m].monitor.name
    return ""
  }

  // One window on the focused monitor showing every monitor's section, the
  // shape sirmenef's overview uses; a per-screen Variants would double-draw
  // the same board.
  readonly property var targetScreen: {
    var screens = Quickshell.screens
    for (var s = 0; s < screens.length; s++) if (screens[s].name === root.focusedMonitorName) return screens[s]
    return screens.length > 0 ? screens[0] : null
  }

  function setting(name, fallback) {
    var value = settings[name]
    return value === undefined || value === null ? fallback : value
  }

  // The summon contract passes a JSON string; the board takes no payload keys,
  // so the argument is accepted and ignored rather than parsed into nothing.
  function open(payloadJson) {
    root.opened = true
    root.selection = null
    // Paint immediately from the IPC objects the shell already holds, then
    // refresh: a fresh reply lands ~0.5 s later and swaps the board in place.
    root.applyBoard()
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.manifestId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function rebuild() {
    root.settleTicks = 0
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    settleTimer.restart()
  }

  // Returns true once every toplevel has answered; the caller decides whether
  // to keep polling.
  function applyBoard() {
    var monitors = [], clients = [], byAddress = ({}), complete = true
    var monitorValues = Hyprland.monitors.values
    for (var m = 0; m < monitorValues.length; m++) {
      var monitorObject = monitorValues[m].lastIpcObject
      if (!monitorObject || monitorObject.id === undefined) complete = false
      else monitors.push(monitorObject)
    }
    var toplevelValues = Hyprland.toplevels.values
    for (var t = 0; t < toplevelValues.length; t++) {
      var clientObject = toplevelValues[t].lastIpcObject
      if (!clientObject || !clientObject.address) {
        complete = false
        continue
      }
      clients.push(clientObject)
      byAddress[String(clientObject.address)] = toplevelValues[t]
    }
    if (monitors.length === 0) return false
    root.toplevelByAddress = byAddress
    root.board = Model.buildBoard(monitors, clients, root.workspaceCount)
    if (!root.validSelection(root.selection)) root.selection = Model.initialSelection(root.board)
    return complete
  }

  function validSelection(sel) {
    if (!sel) return false
    var row = root.board[sel.mon]
    if (!row) return false
    var ws = row.workspaces[sel.ws]
    if (!ws) return false
    if (sel.group === -1) return true
    var group = ws.groups[sel.group]
    return !!(group && group.members[sel.member])
  }

  function move(key) {
    if (!root.validSelection(root.selection)) return
    root.selection = Model.moveSelection(root.board, root.selection, key)
  }

  function activateSelection() {
    if (!root.validSelection(root.selection)) return
    root.activate(Model.activationTarget(root.board, root.selection))
  }

  function activateDigit(digit) {
    if (!root.validSelection(root.selection)) return
    var target = Model.digitTarget(root.board, root.selection, digit)
    if (target) root.activate(target)
  }

  // Lua-form dispatches, the same ones the other Omarchy 4 overview plugins
  // use. Focusing a background tab's address raises it inside its group.
  function activate(target) {
    if (target.kind === "workspace") Hyprland.dispatch("hl.dsp.focus({ workspace = " + target.id + " })")
    else Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + target.address + "\" })")
    root.dismiss()
  }

  function captureFor(address) {
    if (!root.opened) return null
    var toplevel = root.toplevelByAddress[address]
    return toplevel ? toplevel.wayland : null
  }

  // Mirrors services/AppLibrary.qml's fallback chain: the desktop entry's own
  // icon name first, then the app id, then the generic executable icon.
  function appIcon(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = entry && entry.icon ? entry.icon : appId
    var path = Quickshell.iconPath(icon, true)
    return path.length > 0 ? path : Quickshell.iconPath("application-x-executable", true)
  }

  function isTileSelected(monIndex, wsIndex) {
    var sel = root.selection
    return !!sel && sel.group === -1 && sel.mon === monIndex && sel.ws === wsIndex
  }

  function isMemberSelected(monIndex, wsIndex, groupIndex, memberIndex) {
    var sel = root.selection
    return !!sel && sel.mon === monIndex && sel.ws === wsIndex && sel.group === groupIndex && sel.member === memberIndex
  }

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }

  Timer {
    id: settleTimer
    interval: 250
    repeat: true
    // Twelve ticks is three seconds; a toplevel that has not answered by then
    // is drawn without a thumbnail rather than holding the board back.
    onTriggered: {
      root.settleTicks += 1
      if (root.applyBoard() || root.settleTicks >= 12) settleTimer.stop()
    }
  }

  // Compositor events arrive in bursts (a group move emits three), and each
  // refresh blanks every lastIpcObject, so a refresh per event would never
  // settle. Collapse the burst, then refresh once.
  Timer {
    id: rebuildTimer
    interval: 150
    onTriggered: root.rebuild()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!root.opened) return
      var names = ["openwindow", "closewindow", "movewindow", "togglegroup", "moveintogroup", "moveoutofgroup", "workspace", "focusedmon"]
      if (names.indexOf(event.name) !== -1) rebuildTimer.restart()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omaspaces"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.move("left")
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.move("right")
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move("up")
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move("down")
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
          root.move("left")
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.move("right")
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.activateSelection()
          event.accepted = true
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          root.activateDigit(event.key - Qt.Key_0)
          event.accepted = true
        }
      }
    }

    // ---- Board. The tiles are the surface: no card, so they read as
    //      floating over the desktop the scrim dims.
    Column {
      id: boardColumn
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: root.boardMargin
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: headerColumn.height

        Column {
          id: headerColumn
          spacing: Style.space(2)

          Text {
            text: "OVERVIEW"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2
            color: root.faintForeground
          }

          Text {
            text: "Workspaces"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: root.foreground
          }
        }

        Text {
          anchors.right: parent.right
          anchors.bottom: headerColumn.bottom
          textFormat: Text.PlainText
          text: root.board.length === 0
            ? "Loading…"
            : root.workspaceCount + " workspaces · " + root.windowCount + " windows · " + root.groupCount + " groups"
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: root.faintForeground
        }
      }

      // ---- One section per monitor: a row of workspace tiles, then a row of
      //      slots holding the group columns that hang under those tiles.
      Repeater {
        model: root.board

        delegate: Column {
          id: section
          required property var modelData
          required property int index

          readonly property int monIndex: index
          readonly property var monitor: modelData.monitor
          readonly property var workspaces: modelData.workspaces
          readonly property real logicalWidth: monitor.width / monitor.scale
          readonly property real logicalHeight: monitor.height / monitor.scale
          readonly property int tileCount: workspaces.length
          readonly property int tileWidth: Math.max(Style.space(90),
            Math.min(Style.space(300),
              Math.floor((panel.width - root.boardMargin * 2 - root.tileSpacing * (tileCount - 1)) / tileCount)))
          readonly property int tileHeight: Math.round(tileWidth * logicalHeight / logicalWidth)

          // Several groups on one workspace share the tile's width.
          function columnWidth(groups) {
            return Math.min(Math.round(tileWidth * 0.62),
              Math.floor((tileWidth - root.columnSpacing * (groups - 1)) / groups))
          }

          width: boardColumn.width
          spacing: Style.space(8)

          Row {
            visible: root.board.length > 1
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: section.monitor.name + "  " + Math.round(section.logicalWidth) + "×" + Math.round(section.logicalHeight)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.faintForeground
            }

            Rectangle {
              visible: section.monitor.focused
              width: focusedChip.implicitWidth + Style.space(8)
              height: focusedChip.implicitHeight + Style.space(2)
              radius: Style.space(3)
              color: Util.alpha(Color.accent, 0.18)

              Text {
                id: focusedChip
                anchors.centerIn: parent
                text: "FOCUSED"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.accent
              }
            }
          }

          Row {
            id: tileRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.tileSpacing

            Repeater {
              model: section.workspaces

              delegate: BorderSurface {
                id: tile
                required property var modelData
                required property int index

                readonly property var workspace: modelData
                readonly property bool selected: root.isTileSelected(section.monIndex, index)

                width: section.tileWidth
                height: section.tileHeight
                radius: Style.cornerRadius
                color: root.background
                borderSpec: workspace.current ? Border.flat(Color.accent, 2) : Border.flat(root.surfaceBorder, 1)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: root.selection = { mon: section.monIndex, ws: tile.index, group: -1, member: -1 }
                  onClicked: root.activate({ kind: "workspace", id: tile.workspace.id })
                }

                Text {
                  anchors.centerIn: parent
                  visible: tile.workspace.windows.length === 0
                  text: "EMPTY"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  color: root.faintForeground
                }

                // ---- Window thumbnails, placed by their share of the monitor.
                Item {
                  id: tileCanvas
                  anchors.fill: parent
                  anchors.margins: tile.borderTop
                  clip: true

                  Repeater {
                    model: tile.workspace.windows

                    delegate: Item {
                      id: windowItem
                      required property var modelData

                      // A tile mirrors the monitor, so a group contributes
                      // only the tab Hyprland is showing. `visible` tracks tab
                      // state, not workspace visibility, so a group on an
                      // off-screen workspace still has exactly one front tab.
                      visible: modelData.front || modelData.groupSize < 2
                      x: Math.round(modelData.rect.x * tileCanvas.width)
                      y: Math.round(modelData.rect.y * tileCanvas.height)
                      width: Math.max(Style.space(10), Math.round(modelData.rect.w * tileCanvas.width))
                      height: Math.max(Style.space(10), Math.round(modelData.rect.h * tileCanvas.height))

                      Rectangle {
                        anchors.fill: parent
                        radius: root.thumbRadius
                        color: Color.menu.selectedBackground
                      }

                      ScreencopyView {
                        id: windowThumb
                        readonly property real srcAspect: sourceSize.width > 0 && sourceSize.height > 0
                          ? sourceSize.width / sourceSize.height
                          : section.logicalWidth / section.logicalHeight

                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height * srcAspect)
                        height: Math.min(parent.height, parent.width / srcAspect)
                        captureSource: root.captureFor(windowItem.modelData.address)
                        live: true
                        paintCursors: false
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: MultiEffect {
                          maskEnabled: true
                          maskSource: windowThumbMask
                          maskThresholdMin: 0.5
                          maskSpreadAtMin: 1.0
                        }
                      }

                      Item {
                        id: windowThumbMask
                        anchors.centerIn: parent
                        width: windowThumb.width
                        height: windowThumb.height
                        visible: false
                        layer.enabled: true
                        layer.smooth: true

                        Rectangle {
                          anchors.fill: parent
                          radius: root.thumbRadius
                        }
                      }

                      Image {
                        visible: !windowThumb.hasContent
                        anchors.centerIn: parent
                        width: Math.min(Style.font.iconLarge, parent.height / 2)
                        height: width
                        sourceSize.width: Math.max(1, Math.round(width * Screen.devicePixelRatio))
                        sourceSize.height: sourceSize.width
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        source: root.appIcon(windowItem.modelData.appId)
                      }

                      // First cue that a group lives on this workspace; the
                      // column underneath is the second.
                      Rectangle {
                        visible: windowItem.modelData.groupSize > 1
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Style.space(4)
                        width: groupChip.implicitWidth + Style.space(8)
                        height: groupChip.implicitHeight + Style.space(2)
                        radius: Style.space(3)
                        color: Util.alpha(root.background, 0.85)

                        Text {
                          id: groupChip
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: "\uf24d  " + windowItem.modelData.groupSize // nf-fa-clone
                          font.family: root.glyphFamily
                          font.pixelSize: Style.font.caption
                          color: Color.accent
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.selection = { mon: section.monIndex, ws: tile.index, group: -1, member: -1 }
                        onClicked: root.activate({ kind: "window", address: windowItem.modelData.address })
                      }
                    }
                  }
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  width: numberChip.implicitWidth + Style.space(10)
                  height: numberChip.implicitHeight + Style.space(4)
                  radius: Style.space(3)
                  color: Color.menu.selectedBackground

                  Text {
                    id: numberChip
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: tile.workspace.id
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    color: root.foreground
                  }
                }

                Rectangle {
                  visible: tile.workspace.current
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  width: currentChip.implicitWidth + Style.space(8)
                  height: currentChip.implicitHeight + Style.space(2)
                  radius: Style.space(3)
                  color: Util.alpha(Color.accent, 0.18)

                  Text {
                    id: currentChip
                    anchors.centerIn: parent
                    text: "CURRENT"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: Color.accent
                  }
                }

                // Keyboard cursor, drawn outside the tile so it never eats
                // into the thumbnails.
                Rectangle {
                  visible: tile.selected
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: Math.max(1, Style.space(2))
                  border.color: Style.focusStateColor(root.foreground, Color.accent)
                }
              }
            }
          }

          // ---- Group columns. One slot per tile, exactly tile-wide, so a
          //      column can never drift under its neighbour.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.tileSpacing

            Repeater {
              model: section.workspaces

              delegate: Item {
                id: slot
                required property var modelData
                required property int index

                readonly property int railHeight: Style.space(14)

                width: section.tileWidth
                implicitHeight: railHeight + trayRow.height
                height: implicitHeight

                // Rail from where the front tab sits on the tile down into
                // the tray: with two groups on one workspace, two rails leave
                // the tile at the x each group occupies on screen.
                Repeater {
                  model: slot.modelData.groups

                  delegate: Rectangle {
                    required property var modelData

                    readonly property var frontTab: modelData.members[Model.frontIndex(modelData)]

                    x: Math.max(0, Math.min(slot.width - width,
                      Math.round((frontTab.rect.x + frontTab.rect.w / 2) * slot.width - width / 2)))
                    width: Math.max(1, Style.space(2))
                    height: slot.railHeight
                    color: Color.accent
                  }
                }

                Row {
                  id: trayRow
                  y: slot.railHeight
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: root.columnSpacing

                  Repeater {
                    model: slot.modelData.groups

                    delegate: BorderSurface {
                      id: tray
                      required property var modelData
                      required property int index

                      width: section.columnWidth(slot.modelData.groups.length)
                      height: contentTopInset + trayContent.height + contentBottomInset
                      radius: Style.cornerRadius
                      padding: Style.space(8)
                      color: Util.alpha(Color.accent, 0.08)
                      borderSpec: Border.flat(Util.alpha(Color.accent, 0.45), 1)

                      Column {
                        id: trayContent
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.topMargin: tray.contentTopInset
                        anchors.leftMargin: tray.contentLeftInset
                        anchors.rightMargin: tray.contentRightInset
                        spacing: Style.space(8)

                        Text {
                          textFormat: Text.PlainText
                          text: "\uf24d  GROUP · " + tray.modelData.members.length + " TABS" // nf-fa-clone
                          font.family: root.glyphFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          font.letterSpacing: 1
                          color: Color.accent
                          elide: Text.ElideRight
                          width: parent.width
                        }

                        Repeater {
                          model: tray.modelData.members

                          delegate: BorderSurface {
                            id: card
                            required property var modelData
                            required property int index

                            readonly property bool selected: root.isMemberSelected(section.monIndex, slot.index, tray.index, index)
                            readonly property int thumbHeight: Math.round((width - contentLeftInset - contentRightInset) * section.logicalHeight / section.logicalWidth)
                            readonly property int footerHeight: Math.max(Style.space(16), Style.font.bodySmall + Style.space(4))

                            width: trayContent.width
                            height: contentTopInset + thumbHeight + Style.space(4) + footerHeight + contentBottomInset
                            radius: Style.space(6)
                            padding: Style.space(4)
                            color: root.background
                            borderSpec: modelData.front ? Border.flat(Color.accent, 2) : Border.flat(root.surfaceBorder, 1)

                            MouseArea {
                              anchors.fill: parent
                              hoverEnabled: true
                              onEntered: root.selection = { mon: section.monIndex, ws: slot.index, group: tray.index, member: card.index }
                              onClicked: root.activate({ kind: "window", address: card.modelData.address })
                            }

                            Column {
                              anchors.fill: parent
                              anchors.topMargin: card.contentTopInset
                              anchors.rightMargin: card.contentRightInset
                              anchors.bottomMargin: card.contentBottomInset
                              anchors.leftMargin: card.contentLeftInset
                              spacing: Style.space(4)

                              Item {
                                id: cardThumb
                                width: parent.width
                                height: card.thumbHeight

                                Rectangle {
                                  anchors.fill: parent
                                  radius: root.thumbRadius
                                  color: Color.menu.selectedBackground
                                }

                                // A group's background tab is mapped but not
                                // visible, and the compositor still hands
                                // back real pixels for it — that is what
                                // makes a tab column worth drawing.
                                ScreencopyView {
                                  id: memberThumb
                                  readonly property real srcAspect: sourceSize.width > 0 && sourceSize.height > 0
                                    ? sourceSize.width / sourceSize.height
                                    : section.logicalWidth / section.logicalHeight

                                  anchors.centerIn: parent
                                  width: Math.min(parent.width, parent.height * srcAspect)
                                  height: Math.min(parent.height, parent.width / srcAspect)
                                  captureSource: root.captureFor(card.modelData.address)
                                  live: true
                                  paintCursors: false
                                  opacity: card.modelData.front ? 1 : 0.8
                                  layer.enabled: true
                                  layer.smooth: true
                                  layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: memberThumbMask
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1.0
                                  }
                                }

                                Item {
                                  id: memberThumbMask
                                  anchors.centerIn: parent
                                  width: memberThumb.width
                                  height: memberThumb.height
                                  visible: false
                                  layer.enabled: true
                                  layer.smooth: true

                                  Rectangle {
                                    anchors.fill: parent
                                    radius: root.thumbRadius
                                  }
                                }

                                Image {
                                  visible: !memberThumb.hasContent
                                  anchors.centerIn: parent
                                  width: Math.min(Style.font.iconLarge, parent.height - Style.space(4))
                                  height: width
                                  sourceSize.width: Math.max(1, Math.round(width * Screen.devicePixelRatio))
                                  sourceSize.height: sourceSize.width
                                  fillMode: Image.PreserveAspectFit
                                  asynchronous: true
                                  source: root.appIcon(card.modelData.appId)
                                }

                                Rectangle {
                                  visible: card.modelData.front
                                  anchors.right: parent.right
                                  anchors.top: parent.top
                                  anchors.margins: Style.space(3)
                                  width: frontChip.implicitWidth + Style.space(6)
                                  height: frontChip.implicitHeight + Style.space(2)
                                  radius: Style.space(3)
                                  color: Util.alpha(root.background, 0.85)

                                  Text {
                                    id: frontChip
                                    anchors.centerIn: parent
                                    text: "FRONT"
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: Color.accent
                                  }
                                }
                              }

                              Row {
                                width: parent.width
                                height: card.footerHeight
                                spacing: Style.space(4)

                                // Tab number, filled for the tab Hyprland is
                                // showing so the column reads like a stack.
                                Rectangle {
                                  anchors.verticalCenter: parent.verticalCenter
                                  width: card.footerHeight
                                  height: card.footerHeight
                                  radius: width / 2
                                  color: card.modelData.front ? Color.accent : "transparent"
                                  border.width: card.modelData.front ? 0 : 1
                                  border.color: root.surfaceBorder

                                  Text {
                                    anchors.centerIn: parent
                                    textFormat: Text.PlainText
                                    text: card.index + 1
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: card.modelData.front ? root.background : root.foreground
                                  }
                                }

                                Image {
                                  anchors.verticalCenter: parent.verticalCenter
                                  width: Style.font.iconSmall
                                  height: width
                                  sourceSize.width: Math.max(1, Math.round(width * Screen.devicePixelRatio))
                                  sourceSize.height: sourceSize.width
                                  fillMode: Image.PreserveAspectFit
                                  asynchronous: true
                                  source: root.appIcon(card.modelData.appId)
                                }

                                Text {
                                  anchors.verticalCenter: parent.verticalCenter
                                  textFormat: Text.PlainText
                                  text: card.modelData.title
                                  width: parent.width - card.footerHeight - Style.font.iconSmall - Style.space(8)
                                  elide: Text.ElideRight
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.bodySmall
                                  color: root.foreground
                                }
                              }
                            }

                            Rectangle {
                              visible: card.selected
                              anchors.fill: parent
                              anchors.margins: -Style.space(3)
                              radius: Style.space(6)
                              color: "transparent"
                              border.width: Math.max(1, Style.space(2))
                              border.color: Style.focusStateColor(root.foreground, Color.accent)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
