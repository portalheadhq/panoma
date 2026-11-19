import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Panoma: the desktop zooms out. Every window on the workspace shrinks out of
// its real place into a grid, the wallpaper dims behind them, and the dock of
// running apps rises from the bottom edge. Pick a window and it all flies
// back, with that one focused.
//
//   1–9 jump · arrows/hjkl move · enter focus · q close window
//   / filter across all workspaces · tab next app · esc back, then close
//
// Clicking a dock icon (or tab) shows every window of that app, on any
// workspace. Middle-click a thumbnail to close that window.
//
// The whole thing is one number, `progress` (0 = desktop, 1 = overview).
// Keys and binds animate it; a three-finger swipe drags it with the fingers
// (trackBegin / trackUpdate / trackEnd), the way Hyprland's workspace swipe
// follows them.
//
// Mounted for the whole session as a keepLoaded panel, hidden until opened.
// Super+E in bindings.lua calls the IPC handler below.
Item {
  id: root

  readonly property string pluginId: "panoma"

  // ---- State ----------------------------------------------------------------

  // opened: the overlay is mapped. revealed: its tiles have pictures, so it
  // can cover the real windows without anyone noticing the swap.
  property bool opened: false
  property bool loading: false
  property bool revealed: false
  property bool closing: false

  property real progress: 0
  property bool tracking: false
  readonly property bool morphing: tracking || progressAnim.running || sliding || slideAnim.running || departed !== null

  // Snapshot taken on open, so nothing reshuffles under the pointer.
  property string screenName: ""
  property int workspaceId: 0
  // The workspace the desktop shows at progress 0. Changes when a window on
  // another workspace is picked, so the overview lands there.
  property int homeWorkspace: 0
  // The workspace Panoma opened on, and where closing should leave you: a
  // window ({ address }) or a workspace ({ workspace }), or null to stay.
  property int openedOn: 0
  property var landing: null
  property var offset: ({ x: 0, y: 0 })
  property var allWindows: []
  property var gone: ({})
  // Windows sent to another workspace from here (address → id), and fresh
  // positions read back after Hyprland re-tiled them. Kept beside the
  // snapshot so the tiles themselves are never rebuilt.
  property var movedTo: ({})
  property var geometry: ({})
  // Workspace a dragged window is over: 0 the new-workspace tile, -1 none.
  property int dropTarget: -1
  property var names: ({})
  property string wallpaper: ""

  // What is showing: the workspace, a typed filter, or one app everywhere.
  property string query: ""
  property string appKey: ""
  property int selected: -1

  readonly property var liveWindows: allWindows
    .filter(function(w) { return !gone[w.address] })
    .map(function(w) { return movedTo[w.address] !== undefined ? Object.assign({}, w, { workspaceId: movedTo[w.address] }) : w })
  readonly property var liveByAddress: {
    var map = {}
    for (var i = 0; i < liveWindows.length; i++) map[liveWindows[i].address] = liveWindows[i]
    return map
  }
  readonly property bool across: appKey !== "" || query !== ""
  readonly property var apps: Model.groupApps(liveWindows, workspaceId)
  readonly property var shown: appKey !== ""
    ? liveWindows.filter(function(w) { return w.appKey === appKey })
    : query !== "" ? Model.filterWindows(liveWindows, query, names)
    : Model.onWorkspace(liveWindows, workspaceId)
  readonly property var shownIndex: {
    var map = {}
    for (var i = 0; i < shown.length; i++) map[shown[i].address] = i
    return map
  }
  readonly property var selectedWindow: selected >= 0 && selected < shown.length ? shown[selected] : null
  readonly property string activeAppKey: appKey !== "" ? appKey : (selectedWindow ? selectedWindow.appKey : "")
  readonly property int workspaceCount: {
    var seen = {}
    var n = 0
    for (var i = 0; i < shown.length; i++)
      if (!seen[shown[i].workspaceId]) { seen[shown[i].workspaceId] = true; n++ }
    return n
  }

  // Numbered workspaces on this monitor, as Hyprland knows them.
  readonly property var hyprWorkspaceIds: {
    var ids = []
    var list = Hyprland.workspaces.values
    for (var i = 0; i < list.length; i++) {
      var ws = list[i]
      if (ws && ws.id > 0 && ws.monitor && ws.monitor.name === screenName) ids.push(ws.id)
    }
    return ids
  }
  readonly property var strip: opened ? Model.workspaceStrip(hyprWorkspaceIds, liveWindows, workspaceId) : []
  readonly property int newWorkspaceId: {
    var ids = strip.map(function(w) { return w.id })
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) if (all[i]) ids.push(all[i].id)
    return Model.nextFreeWorkspace(ids)
  }

  function workspaceOf(w) {
    return w && movedTo[w.address] !== undefined ? movedTo[w.address] : (w ? w.workspaceId : 0)
  }

  function geometryOf(w) {
    return w && geometry[w.address] ? geometry[w.address] : w
  }

  // Tiles report whether they have a picture yet.
  property var captured: ({})

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- Motion ---------------------------------------------------------------

  property var pendingDone: null

  NumberAnimation {
    id: progressAnim
    target: root
    property: "progress"
    easing.type: Easing.Bezier
    easing.bezierCurve: Style.easeOut
    onFinished: {
      var done = root.pendingDone
      root.pendingDone = null
      if (done) done()
    }
  }

  // Animates progress to `to`, taking the share of `ms` the distance left
  // calls for, so a half-finished swipe doesn't crawl home.
  function animateTo(to, ms, done) {
    pendingDone = null
    progressAnim.stop()
    var distance = Math.abs(to - progress)
    var duration = Style.duration(Math.max(120, ms * distance))
    if (distance < 0.001 || duration <= 0) {
      progress = to
      if (done) done()
      return
    }
    pendingDone = done || null
    progressAnim.from = progress
    progressAnim.to = to
    progressAnim.duration = duration
    progressAnim.start()
  }

  // ---- Shell contract -------------------------------------------------------

  function open(payloadJson) { show() }
  function close() { dismiss(null) }

  function show() {
    if (closing) {
      // Changed its mind halfway out: go back in from where it is.
      closing = false
      homeWorkspace = workspaceId
      animateTo(1, 300)
      return
    }
    if (opened || loading) return
    loading = true
    clientsJson = null
    monitorsJson = null
    wallpaperPath = null
    Hyprland.refreshToplevels()
    lookProc.running = true
    clientsProc.running = true
    monitorsProc.running = true
    wallpaperProc.running = true
  }

  function toggle() {
    if ((opened && !closing) || loading) dismiss(null)
    else show()
  }

  // Back to the desktop, everything flying home. With a target, that window
  // is focused first, so whatever Hyprland switches to is ready underneath.
  function dismiss(target) {
    if (loading && !opened) { loading = false; return }
    if (!opened) return
    revealTimer.stop()
    tracking = false
    if (target) {
      // Now, so its workspace is the one underneath while everything flies
      // home; and again once the overlay is gone (see `land`).
      focusNow({ address: target.address })
      landing = { address: target.address }
      landingWorkspace = target.workspaceId
      activeAddress = target.address
      homeWorkspace = target.workspaceId
    } else {
      homeWorkspace = workspaceId
      var last = Model.mostRecent(Model.onWorkspace(liveWindows, workspaceId))
      landing = workspaceId !== openedOn ? (last ? { address: last.address } : { workspace: workspaceId }) : null
      if (workspaceId !== openedOn) activeAddress = last ? last.address : ""
    }
    // Releasing the keyboard (closing does that first) makes Hyprland refocus
    // the window it had before; land again right after, still under cover.
    if (landing) landTimer.restart()
    closing = true
    if (!revealed) { finishClose(); return }
    animateTo(0, 260, finishClose)
  }

  function focusNow(where) {
    if (where && where.address)
      Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + where.address + '" })'])
    else if (where && where.workspace > 0)
      Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "' + where.workspace + '" })'])
  }

  // When the overlay unmaps, Hyprland hands focus back to the window that had
  // it before Panoma, which drags you back to the workspace it lives on. So
  // the choice is made again, just after that has happened.
  Timer {
    id: landTimer
    interval: 50
    onTriggered: root.focusNow(root.landing)
  }

  // After the overlay is gone: only if something still moved focus away.
  Timer {
    id: landCheck
    interval: 40
    onTriggered: {
      var where = root.landing
      root.landing = null
      if (!where || root.opened) return
      var active = Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id : -1
      var wanted = where.workspace > 0 ? where.workspace : root.landingWorkspace
      if (wanted > 0 && active !== wanted) root.focusNow(where)
    }
  }
  property int landingWorkspace: 0

  function finishClose() {
    progressAnim.stop()
    pendingDone = null
    opened = false
    revealed = false
    closing = false
    tracking = false
    progress = 0
    query = ""
    appKey = ""
    selected = -1
    gone = ({})
    movedTo = ({})
    geometry = ({})
    dropTarget = -1
    slideAnim.stop()
    slideDone = null
    slide = 0
    sliding = false
    peekWorkspace = -1
    peekDir = 0
    departed = null
    captured = ({})
    allWindows = []
    if (landing) landCheck.restart()
  }

  // ---- Swipe ----------------------------------------------------------------

  property real trackBase: 0
  property real trackLast: 0
  property double trackLastAt: 0
  property real trackVelocity: 0
  // Set when the fingers lift before the overlay could even show.
  property int trackVerdict: -1

  function trackBegin() {
    tracking = true
    trackVerdict = -1
    pendingDone = null
    progressAnim.stop()
    closing = false
    homeWorkspace = workspaceId
    trackBase = opened ? progress : 0
    trackLast = trackBase
    trackLastAt = Date.now()
    trackVelocity = 0
    if (!opened && !loading) show()
  }

  // delta: progress gained since the swipe began (up is positive).
  function trackUpdate(delta) {
    if (!tracking) return
    var now = Date.now()
    var p = Model.clamp01(trackBase + delta)
    var dt = Math.max(1, now - trackLastAt) / 1000
    // Smoothed, so one jittery sample doesn't decide the release.
    trackVelocity = 0.6 * trackVelocity + 0.4 * ((p - trackLast) / dt)
    trackLast = p
    trackLastAt = now
    if (opened) progress = p
  }

  function trackEnd(cancelled) {
    if (!tracking) return
    tracking = false
    var target = cancelled ? (trackBase >= 0.5 ? 1 : 0) : Model.releaseTarget(trackLast, trackVelocity)
    if (!opened) {
      // Still loading: the reveal will act on this.
      trackVerdict = target
      return
    }
    if (target === 1) animateTo(1, 300)
    else dismiss(null)
  }

  // Raw touchpad swipes, read straight from the device (swipe-reader.sh), so
  // the overview can follow the fingers; Hyprland's own gesture binds only
  // say a swipe happened once it is over. Needs read access to the touchpad
  // node; until then the reader exits and the Hyprland binds (`gesture`
  // below) open and close it instead.
  property bool swipeReaderActive: false
  // Three fingers are down and the overview is loading out of sight, so a
  // swipe up has nothing left to wait for. Stays hidden (and click-through)
  // until the swipe turns out to be vertical.
  property bool preparing: false
  property string swipePhase: ""
  property real swipeDx: 0
  property real swipeDy: 0
  // Finger travel, in libinput's accelerated units, for the whole way open;
  // Hyprland's workspace swipe uses the same scale (workspace_swipe_distance).
  property real swipeDistance: 300

  function onSwipeLine(line) {
    var e = Model.parseSwipeLine(line)
    if (!e) return
    if (e.type === "begin") {
      swipePhase = e.fingers === 3 ? "deciding" : "ignored"
      swipeDx = 0
      swipeDy = 0
      if (swipePhase === "deciding" && !opened && !loading) {
        preparing = true
        show()
      }
      return
    }
    if (e.type === "end") {
      if (swipePhase === "vertical") trackEnd(e.cancelled)
      else if (swipePhase === "horizontal") slideEnd(e.cancelled)
      else cancelPrepared()
      swipePhase = ""
      return
    }
    if (swipePhase !== "deciding" && swipePhase !== "vertical" && swipePhase !== "horizontal") return
    swipeDx += e.dx
    swipeDy += e.dy
    if (swipePhase === "deciding") {
      var axis = Model.swipeAxis(swipeDx, swipeDy, 10)
      if (axis === "") return
      var overview = opened && revealed && !closing
      if (axis === "horizontal") {
        // In the overview, sideways moves between workspaces there. On the
        // desktop it is Hyprland's own workspace swipe.
        if (overview && canSlide()) {
          swipePhase = "horizontal"
          slideBegin()
        } else {
          swipePhase = "ignored"
          cancelPrepared()
          return
        }
      } else if (!overview && swipeDy > 0) {
        // Down on the desktop is nothing.
        swipePhase = "ignored"
        cancelPrepared()
        return
      } else {
        swipePhase = "vertical"
        preparing = false
        trackBegin()
      }
    }
    if (swipePhase === "horizontal") slideTo(slideBase + swipeDx / swipeDistance)
    else trackUpdate(-swipeDy / swipeDistance)
  }

  // ---- Sliding between workspaces --------------------------------------------
  // slide: how far the grid has moved sideways, in screen widths. Negative
  // moves it left and brings in the workspace to the right (peekDir +1).

  property real slide: 0
  property real slideBase: 0
  property int peekWorkspace: -1
  property int peekDir: 0
  property bool sliding: false
  // The workspace just left, drawn off to its side while its tiles fade.
  property var departed: null
  property real slideLast: 0
  property double slideLastAt: 0
  property real slideVelocity: 0
  property var slideDone: null

  readonly property var peekWindows: peekWorkspace > 0 ? Model.onWorkspace(liveWindows, peekWorkspace) : []
  readonly property var peekIndex: {
    var map = {}
    for (var i = 0; i < peekWindows.length; i++) map[peekWindows[i].address] = i
    return map
  }

  NumberAnimation {
    id: slideAnim
    target: root
    property: "slide"
    easing.type: Easing.Bezier
    easing.bezierCurve: Style.easeOut
    onFinished: {
      var done = root.slideDone
      root.slideDone = null
      if (done) done()
    }
  }

  function canSlide() {
    return opened && revealed && !closing && !across
  }

  function setPeek(dir) {
    if (dir === peekDir && peekWorkspace > 0) return
    var ids = strip.map(function(w) { return w.id })
    var has = Model.onWorkspace(liveWindows, workspaceId).length > 0
    var id = Model.neighborWorkspace(ids, workspaceId, dir, has)
    peekWorkspace = id
    peekDir = id > 0 ? dir : 0
  }

  function slideBegin() {
    sliding = true
    slideAnim.stop()
    slideDone = null
    slideBase = slide
    slideLast = slide
    slideLastAt = Date.now()
    slideVelocity = 0
  }

  // amount: where the fingers have put the grid, in screen widths.
  function slideTo(amount) {
    if (!sliding) return
    if (amount !== 0) setPeek(amount < 0 ? 1 : -1)
    // Nothing on that side: it gives a little, then resists.
    var s = peekWorkspace > 0 ? amount : amount * 0.15
    s = Math.max(-1, Math.min(1, s))
    var now = Date.now()
    var dt = Math.max(1, now - slideLastAt) / 1000
    slideVelocity = 0.6 * slideVelocity + 0.4 * ((s - slideLast) / dt)
    slideLast = s
    slideLastAt = now
    slide = s
  }

  function slideEnd(cancelled) {
    if (!sliding) return
    sliding = false
    // Velocity towards the workspace coming in.
    var towards = slide < 0 ? -slideVelocity : slideVelocity
    var commit = !cancelled && peekWorkspace > 0 && Model.releaseTarget(Math.abs(slide), towards) === 1
    if (commit) {
      animateSlide(slide < 0 ? -1 : 1, commitSlide)
    } else {
      animateSlide(0, function() { root.peekWorkspace = -1; root.peekDir = 0 })
      // Hyprland ran its own workspace swipe under the overlay.
      syncTimer.restart()
    }
  }

  function animateSlide(to, done) {
    slideAnim.stop()
    var distance = Math.abs(to - slide)
    var duration = Style.duration(Math.max(100, 300 * distance))
    if (distance < 0.001 || duration <= 0) {
      slide = to
      if (done) done()
      return
    }
    slideDone = done || null
    slideAnim.from = slide
    slideAnim.to = to
    slideAnim.duration = duration
    slideAnim.start()
  }

  // The incoming workspace has slid fully into place: it becomes the one
  // shown, exactly where it already is.
  function commitSlide() {
    var id = peekWorkspace
    departed = { ws: workspaceId, dir: slide < 0 ? -1 : 1 }
    viewWorkspace(id)
    slide = 0
    peekWorkspace = -1
    peekDir = 0
    departTimer.restart()
    syncTimer.restart()
  }

  // Ctrl+←/→ and the like: the same slide, animated.
  function stepWorkspace(dir) {
    if (!canSlide() || sliding) return
    slideAnim.stop()
    setPeek(dir)
    if (peekWorkspace <= 0) return
    animateSlide(dir > 0 ? -1 : 1, commitSlide)
  }

  Timer {
    id: departTimer
    interval: 260
    onTriggered: root.departed = null
  }

  // Whatever Hyprland's own swipe did underneath, end on the workspace shown.
  Timer {
    id: syncTimer
    interval: 150
    onTriggered: {
      if (!root.opened || root.closing) return
      var monitor = Hyprland.focusedMonitor
      var active = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (active === root.workspaceId) return
      var last = Model.mostRecent(Model.onWorkspace(root.liveWindows, root.workspaceId))
      root.focusNow(last ? { address: last.address } : { workspace: root.workspaceId })
    }
  }

  function cancelPrepared() {
    if (!preparing) return
    preparing = false
    if (loading) loading = false
    else if (opened && !revealed) finishClose()
  }

  Process {
    id: swipeProc
    // Plugins load from qs:// URLs, not file://; either way only the path
    // is wanted.
    command: ["bash", Qt.resolvedUrl("swipe-reader.sh").toString().replace(/^[a-z]+:\/\//, "")]
    running: true
    stdout: SplitParser {
      onRead: (line) => {
        root.swipeReaderActive = true
        root.onSwipeLine(line)
      }
    }
    onExited: {
      root.swipeReaderActive = false
      root.swipePhase = ""
      swipeRetry.start()
    }
  }

  // The touchpad may become readable later (permission granted, a device
  // reattached); try again now and then.
  Timer {
    id: swipeRetry
    interval: 15000
    onTriggered: swipeProc.running = true
  }

  // ---- Apps -----------------------------------------------------------------

  // Dialogs often append to their app's reverse-DNS id, so trailing segments
  // are dropped until the app's own entry turns up (never below three).
  function entryFor(appId) {
    var host = Model.webAppHost(appId)
    if (host) {
      var all = DesktopEntries.applications.values
      for (var i = 0; i < all.length; i++)
        if (String(all[i].execString || "").indexOf("//" + host) !== -1) return all[i]
      return null
    }
    var name = String(appId || "")
    while (name) {
      var entry = DesktopEntries.heuristicLookup(name)
      if (entry) return entry
      var dot = name.lastIndexOf(".")
      if (dot <= 0 || name.split(".").length <= 3) return null
      name = name.slice(0, dot)
    }
    return null
  }

  function iconPath(icon) {
    icon = String(icon || "")
    if (icon.indexOf("/") === 0) return Util.fileUrl(icon)
    return icon ? Quickshell.iconPath(icon, true) : ""
  }

  // Desktop-entry lookups are slow enough to show on open; apps don't change
  // their icon or name, so each is looked up once per session.
  property var iconCache: ({})
  property var nameCache: ({})

  function appIcon(appId) {
    var key = String(appId || "")
    if (iconCache[key] !== undefined) return iconCache[key]
    var entry = entryFor(appId)
    var icon = entry ? iconPath(entry.icon) : ""
    icon = icon || (key ? Quickshell.iconPath(key.toLowerCase(), true) : "")
    iconCache[key] = icon
    return icon
  }

  function appName(appId) {
    var key = String(appId || "")
    if (nameCache[key] !== undefined) return nameCache[key]
    var entry = entryFor(appId)
    var name = entry && entry.name ? entry.name : key
    nameCache[key] = name
    return name
  }

  // The live Hyprland handle for a window, whose Wayland side is what the
  // thumbnail captures. Null until Quickshell has heard of the window.
  function toplevelFor(address) {
    var want = Model.normalizeAddress(address)
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++)
      if (Model.normalizeAddress(list[i].address) === want) return list[i]
    return null
  }

  // ---- Actions --------------------------------------------------------------

  function focusWindow(w) {
    if (w) dismiss(w)
  }

  function closeWindow(w) {
    if (!w) return
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + w.address + '" })'])
    var next = Object.assign({}, gone)
    next[w.address] = true
    gone = next
    if (appKey !== "" && !liveWindows.some(function(x) { return x.appKey === appKey })) appKey = ""
    selected = Math.min(selected, shown.length - 1)
  }

  // Shows another workspace's windows, switching Hyprland to it underneath so
  // closing lands there.
  function viewWorkspace(id) {
    if (closing || !(id > 0)) return
    appKey = ""
    query = ""
    if (id !== workspaceId) {
      workspaceId = id
      homeWorkspace = id
      // Its last window rather than the bare workspace: Hyprland remembers
      // the window, and returns focus to it when Panoma lets go of the
      // keyboard, so you stay here instead of bouncing back.
      var last = Model.mostRecent(Model.onWorkspace(liveWindows, id))
      focusNow(last ? { address: last.address } : { workspace: id })
    }
    selectFocused()
  }

  // Sends a window to a workspace, staying here.
  function moveWindow(w, id) {
    if (!w || !(id > 0) || workspaceOf(w) === id) return
    Quickshell.execDetached(["hyprctl", "dispatch",
      'hl.dsp.window.move({ workspace = "' + id + '", follow = false, window = "address:' + w.address + '" })'])
    var next = Object.assign({}, movedTo)
    next[w.address] = id
    movedTo = next
    selected = Math.min(Math.max(selected, 0), shown.length - 1)
    geometryRefresh.restart()
  }

  // Where Hyprland put things after a move, so closing morphs to the truth.
  Timer {
    id: geometryRefresh
    interval: 250
    onTriggered: if (root.opened) geometryProc.running = true
  }

  Process {
    id: geometryProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.opened) return
        var fresh = Model.snapshotWindows(root.parseJson(text) || [])
        var map = {}
        for (var i = 0; i < fresh.length; i++) map[fresh[i].address] = fresh[i]
        root.geometry = map
      }
    }
  }

  function showApp(key) {
    query = ""
    appKey = key
    selected = shown.length > 0 ? 0 : -1
  }

  function stepApp(step) {
    if (apps.length === 0) return
    var current = -1
    var from = appKey !== "" ? appKey : activeAppKey
    for (var i = 0; i < apps.length; i++) if (apps[i].key === from) current = i
    // From the workspace view, tab goes to the selected window's app first.
    var next = appKey === "" && current >= 0 ? current : Model.cycle(current, apps.length, step)
    showApp(apps[next].key)
  }

  // Query first: leaving app mode re-syncs the filter box from it.
  function setQuery(text) {
    query = text
    appKey = ""
    selected = shown.length > 0 ? 0 : -1
  }

  // Esc peels back one layer: app or filter first, then the overlay.
  function back() {
    if (across) {
      appKey = ""
      query = ""
      selectFocused()
    } else {
      dismiss(null)
    }
  }

  function selectFocused() {
    var best = -1
    for (var i = 0; i < shown.length; i++)
      if (best < 0 || shown[i].focusHistoryId < shown[best].focusHistoryId) best = i
    selected = best
  }

  // ---- Opening --------------------------------------------------------------

  property var clientsJson: null
  property var monitorsJson: null
  property var wallpaperPath: null

  function parseJson(text) {
    try {
      return JSON.parse(text)
    } catch (e) {
      return null
    }
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (monitor && screens[i].name === monitor.name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  // Kept decoded between opens: a full-size image takes ~100ms+ to decode,
  // which would otherwise stall every open.
  function applyWallpaper(path) {
    var next = path && !isVideo(path) ? Util.fileUrl(path) : ""
    if (next !== wallpaper) wallpaper = next
  }

  Component.onCompleted: {
    wallpaperProc.running = true
    lookProc.running = true
  }

  // Hyprland's border and corner rounding, so tiles match the real windows
  // at the start of the motion. Read again on every open (a config reload
  // may have changed them); never waited for.
  property int hyprBorderSize: 0
  property int hyprRounding: 0
  property color hyprActiveBorder: Color.accent
  property color hyprInactiveBorder: "transparent"
  // The window drawn with the active border at progress 0.
  property string activeAddress: ""

  Process {
    id: lookProc
    command: ["bash", "-c", "for o in general:border_size decoration:rounding general:col.active_border general:col.inactive_border; do hyprctl getoption \"$o\" -j; done | jq -sc ."]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = root.parseJson(text)
        if (!Array.isArray(v) || v.length < 4) return
        root.hyprBorderSize = Math.max(0, Number(v[0] && v[0].int) || 0)
        root.hyprRounding = Math.max(0, Number(v[1] && v[1].int) || 0)
        root.hyprActiveBorder = Model.parseBorderColor(v[2] && v[2].gradient, String(Color.accent))
        root.hyprInactiveBorder = Model.parseBorderColor(v[3] && v[3].gradient, "#00000000")
      }
    }
  }

  Connections {
    target: Color
    function onAccentChanged() { if (!root.opened && !root.loading) { root.wallpaperPath = null; wallpaperProc.running = true } }
    function onBackgroundChanged() { if (!root.opened && !root.loading) { root.wallpaperPath = null; wallpaperProc.running = true } }
  }

  function isVideo(path) {
    return /\.(mp4|webm|mkv|mov|avi|gif)$/i.test(String(path || ""))
  }

  function finishOpen() {
    if (!loading || clientsJson === null || monitorsJson === null || wallpaperPath === null) return
    loading = false

    var screen = focusedScreen()
    if (!screen) return
    screenName = screen.name
    offset = Model.monitorOffset(monitorsJson, screen.name)
    applyWallpaper(wallpaperPath)
    var windows = Model.snapshotWindows(clientsJson)
    var map = {}
    for (var i = 0; i < windows.length; i++)
      if (!map[windows[i].appKey]) map[windows[i].appKey] = appName(windows[i].appId)
    names = map

    var monitor = Hyprland.focusedMonitor
    var ws = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 0
    if (!ws) {
      var focused = Model.mostRecent(windows)
      ws = focused ? focused.workspaceId : 1
    }
    workspaceId = ws
    homeWorkspace = ws
    openedOn = ws
    var focusedNow = Model.mostRecent(windows)
    activeAddress = focusedNow && focusedNow.focusHistoryId === 0 ? focusedNow.address : ""
    landing = null

    query = ""
    appKey = ""
    gone = ({})
    captured = ({})
    progress = tracking ? Model.clamp01(trackLast) : 0
    revealed = false
    closing = false
    allWindows = windows
    selectFocused()
    opened = true
    revealWaited = 0
    revealTimer.start()
  }

  // Waits (briefly) for every window on the workspace to have a picture, so
  // the overlay covers the real windows with identical ones.
  property int revealWaited: 0

  function homeCaptured() {
    for (var i = 0; i < allWindows.length; i++)
      if (allWindows[i].workspaceId === homeWorkspace && captured[allWindows[i].address] !== true) return false
    return true
  }

  Timer {
    id: revealTimer
    interval: 16
    repeat: true
    onTriggered: {
      root.revealWaited += interval
      // Loaded ahead of a swipe that hasn't picked a direction yet.
      if (root.preparing) {
        if (root.revealWaited > 4000) root.cancelPrepared()
        return
      }
      if (!root.homeCaptured() && root.revealWaited < 200) return
      stop()
      root.revealed = true
      if (root.tracking) {
        root.progress = Model.clamp01(root.trackLast)
      } else if (root.trackVerdict === 0) {
        root.finishClose()
      } else {
        root.trackVerdict = -1
        root.animateTo(1, 320)
      }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.clientsJson = root.parseJson(text) || []; root.finishOpen() }
    }
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.monitorsJson = root.parseJson(text) || []; root.finishOpen() }
    }
  }

  // The wallpaper the background service shows, so the overview zooms out
  // over the same picture.
  Process {
    id: wallpaperProc
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.wallpaperPath = String(text || "").trim(); if (!root.loading) root.applyWallpaper(root.wallpaperPath); root.finishOpen() }
    }
  }

  IpcHandler {
    target: "panoma"

    function open(): string { root.show(); return "opening" }
    function toggle(): string { root.toggle(); return root.opened && !root.closing || root.loading ? "opening" : "closing" }
    function close(): string { root.dismiss(null); return "closing" }
    // Only while open: one app on every workspace, or a typed filter.
    function app(name: string): string {
      if (!root.opened) return "closed"
      var want = String(name).toLowerCase()
      for (var i = 0; i < root.apps.length; i++) {
        var a = root.apps[i]
        if (a.key === want || String(root.appName(a.appId)).toLowerCase() === want) { root.showApp(a.key); return a.key }
      }
      return "no such app"
    }
    function filter(text: string): string {
      if (!root.opened) return "closed"
      root.setQuery(text)
      return root.shown.length + " shown"
    }
    // Drags the overview to a progress as a swipe would, for trying the
    // motion from a terminal: scrub 0.4, then release.
    function scrub(value: string): string {
      if (!root.tracking) root.trackBegin()
      root.trackUpdate(Number(value) - root.trackBase)
      return String(root.progress)
    }
    function release(): string { root.trackEnd(false); return "released" }
    // Sideways, as a three-finger swipe in the overview: slide -0.4 (towards
    // the next workspace), then slideRelease. step 1 / step -1 animates.
    function slide(amount: string): string {
      if (!root.canSlide() && !root.sliding) return "can't slide here"
      if (!root.sliding) root.slideBegin()
      root.slideTo(Number(amount))
      return root.slide + " peek " + root.peekWorkspace
    }
    function slideRelease(): string { root.slideEnd(false); return "released" }
    function step(dir: string): string { root.stepWorkspace(Number(dir)); return "stepping" }
    // Only while open: show a workspace, or send the selected window to one.
    function workspace(id: string): string { root.viewWorkspace(Number(id)); return String(root.workspaceId) }
    function select(index: string): string {
      var i = Number(index)
      if (i >= 0 && i < root.shown.length) root.selected = i
      return root.selectedWindow ? root.appName(root.selectedWindow.appId) : ""
    }
    function activate(): string {
      var w = root.selectedWindow
      root.focusWindow(w)
      return w ? root.appName(w.appId) : ""
    }
    function send(id: string): string { root.moveWindow(root.selectedWindow, Number(id)); return root.shown.length + " shown" }
    // Hyprland's three-finger up/down binds. Ignored while the touchpad
    // reader is tracking the fingers itself.
    function gesture(direction: string): string {
      if (root.swipeReaderActive) return "tracked"
      if (direction === "up") root.show()
      else if (direction === "down") root.dismiss(null)
      return direction
    }

    // omarchy-shell panoma status | jq
    function status(): string {
      return JSON.stringify({
        opened: root.opened,
        swipeReader: root.swipeReaderActive,
        revealed: root.revealed,
        closing: root.closing,
        progress: root.progress,
        screen: root.screenName,
        offset: root.offset,
        workspace: root.workspaceId,
        strip: root.strip.map(function(w) { return w.id + ":" + w.windows.length }),
        wallpaper: root.wallpaper,
        query: root.query,
        app: root.appKey,
        selected: root.selected,
        windows: root.shown.map(function(w) {
          return {
            app: root.appName(w.appId),
            title: w.title,
            workspace: w.workspaceId,
            handle: root.toplevelFor(w.address) !== null,
            picture: root.captured[w.address] === true
          }
        }),
        dock: root.apps.map(function(a) { return { app: root.appName(a.appId), windows: a.count, here: a.onWorkspace } })
      })
    }
  }

  // ---- Overlay --------------------------------------------------------------

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: win

        required property var modelData
        readonly property bool here: root.opened && modelData.name === root.screenName
        readonly property real p: root.progress
        // Decorations (header, dock) trail the windows a little.
        readonly property real late: Math.max(0, Math.min(1, (p - 0.25) / 0.75))

        screen: modelData
        visible: here
        color: "transparent"
        anchors { left: true; right: true; top: true; bottom: true }
        // Below the bar's reserved space, so the bar stays in view.
        exclusionMode: ExclusionMode.Normal
        WlrLayershell.namespace: "panoma"
        WlrLayershell.layer: WlrLayer.Overlay
        // Only once it covers the real windows: taking focus earlier would
        // flash their borders inactive.
        WlrLayershell.keyboardFocus: here && root.revealed && !root.closing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Click-through while it is still invisible (loading ahead of a swipe).
        mask: root.revealed ? null : passThrough
        Region { id: passThrough }

        onHereChanged: if (here) keys.forceActiveFocus()

        function dropTargetAt(at) {
          var q = stage.mapToItem(wsStrip, at.x, at.y)
          return wsStrip.workspaceAt(q.x, q.y)
        }

        readonly property int gap: Style.space(24)
        readonly property int captionHeight: Style.space(24)
        readonly property var slots: Model.layoutRows(
          root.shown,
          { x: grid.x, y: grid.y, width: grid.width, height: Math.max(0, grid.height - captionHeight) },
          gap,
          grid.height)

        // The workspace sliding in, laid out in the same grid.
        readonly property var peekSlots: Model.layoutRows(
          root.peekWindows,
          { x: grid.x, y: grid.y, width: grid.width, height: Math.max(0, grid.height - captionHeight) },
          gap,
          grid.height)

        readonly property color muted: Util.alpha(Color.foreground, 0.55)

        Item {
          id: stage
          anchors.fill: parent
          // Held invisible until the pictures are in, then swapped in at once:
          // at progress 0 it looks exactly like the desktop it covers.
          opacity: root.revealed ? 1 : 0

          // ---- Wallpaper ----

          Rectangle {
            anchors.fill: parent
            color: Color.background
          }

          // Laid out over the whole monitor, so it lines up with the real one
          // behind the bar.
          Image {
            x: -root.offset.x + (win.modelData ? win.modelData.x : 0)
            y: -root.offset.y + (win.modelData ? win.modelData.y : 0)
            width: win.modelData ? win.modelData.width : parent.width
            height: win.modelData ? win.modelData.height : parent.height
            visible: root.wallpaper !== ""
            source: root.wallpaper
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            smooth: true
          }

          // The wallpaper is only there so progress 0 matches the desktop; the
          // overview itself sits on near-black, so the windows stand out.
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.88 * win.p)
          }

          MouseArea {
            anchors.fill: parent
            enabled: win.p > 0.99
            onClicked: root.dismiss(null)
          }

          // ---- Windows ----

          // ---- Workspaces ----

          WorkspaceStrip {
            id: wsStrip
            anchors.top: header.bottom
            anchors.topMargin: Style.space(16)
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, parent.width - 2 * Style.space(32))
            height: implicitHeight
            z: 3000
            opacity: win.late
            visible: opacity > 0
            transform: Translate { y: -Style.space(18) * (1 - win.late) }
            workspaces: root.strip
            offset: root.offset
            areaWidth: stage.width
            areaHeight: stage.height
            dropTarget: root.dropTarget
            newWorkspaceId: root.newWorkspaceId
            dropLabel: strings.t("drop.move")
            iconFor: function(appId) { return root.appIcon(appId) }
            nameFor: function(appId) { return root.appName(appId) }
            geometryFor: function(w) { return root.geometryOf(w) }
            onPicked: (id) => {
              root.viewWorkspace(id)
              keys.forceActiveFocus()
            }
          }

          Item {
            id: grid
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: wsStrip.bottom
            anchors.bottom: dock.top
            anchors.margins: Style.space(32)
            anchors.topMargin: Style.space(20)
            anchors.bottomMargin: Style.space(16)
          }

          Repeater {
            // Every window, shown or not, so filtering fades tiles in and out
            // and slides the rest instead of rebuilding them all.
            model: win.here ? root.allWindows : []

            WindowTile {
              id: tile

              required property var modelData
              readonly property int shownAt: root.shownIndex[modelData.address] !== undefined ? root.shownIndex[modelData.address] : -1
              readonly property bool inView: shownAt >= 0
              // The window as it is now (moved, say), not as first snapshotted.
              readonly property var current: root.liveByAddress[modelData.address] || modelData
              readonly property bool home: root.workspaceOf(modelData) === root.homeWorkspace
              readonly property bool isGone: root.gone[modelData.address] === true
              readonly property var handle: root.toplevelFor(modelData.address)
              readonly property var real: Model.realRect(root.geometryOf(modelData), root.offset)

              // Last place in the grid, kept while filtered out so it fades
              // where it was.
              readonly property int wsNow: root.workspaceOf(modelData)
              readonly property bool inPeek: root.peekWorkspace > 0 && wsNow === root.peekWorkspace && !isGone
              readonly property int peekAt: inPeek && root.peekIndex[modelData.address] !== undefined ? root.peekIndex[modelData.address] : -1
              readonly property var gridSlot: inView && win.slots[shownAt] ? win.slots[shownAt]
                : (peekAt >= 0 && win.peekSlots[peekAt] ? win.peekSlots[peekAt] : null)
              // Sideways, while sliding between workspaces.
              readonly property real shiftX: {
                if (inView && !root.across) return root.slide * stage.width
                if (inPeek) return (root.slide + root.peekDir) * stage.width
                if (root.departed && wsNow === root.departed.ws) return root.departed.dir * stage.width
                return 0
              }
              property var lastSlot: null
              onGridSlotChanged: if (gridSlot) lastSlot = gridSlot
              readonly property var slot: gridSlot || lastSlot || real

              property real shownFactor: inView || inPeek ? 1 : 0
              Behavior on shownFactor { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

              readonly property var frameNow: Model.tileFrame(real, slot, win.p, home, shownFactor, isGone)

              window: modelData
              x: frameNow.rect.x + shiftX + (dragging ? dragOffset.x : 0)
              y: frameNow.rect.y + (dragging ? dragOffset.y : 0)
              width: frameNow.rect.width
              height: frameNow.rect.height
              opacity: frameNow.opacity
              visible: opacity > 0.001
              // The real stacking order while morphing: floating over tiled,
              // most recently focused on top.
              z: dragging ? 5000 : (modelData.floating ? 2000 : 1000) - Math.min(999, modelData.focusHistoryId)

              // Re-layouts (filtering, a window closed) glide; the morph
              // itself is driven frame by frame and must not lag behind.
              Behavior on x { enabled: !root.morphing && !tile.dragging; NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
              Behavior on y { enabled: !root.morphing && !tile.dragging; NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
              Behavior on width { enabled: !root.morphing && !tile.dragging; NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
              Behavior on height { enabled: !root.morphing && !tile.dragging; NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }

              toplevel: handle ? handle.wayland : null
              capturing: win.here && !isGone
              live: win.here && (home || inView)
              reveal: win.p
              selected: inView && root.selected === shownAt
              captionHeight: win.captionHeight
              appName: root.appName(modelData.appId)
              icon: root.appIcon(modelData.appId)
              draggable: !root.closing && !root.sliding
              cornerRadius: root.hyprRounding
              hyprBorderWidth: root.hyprBorderSize
              hyprBorder: modelData.address === root.activeAddress ? root.hyprActiveBorder : root.hyprInactiveBorder
              badge: !inView ? ""
                : root.across ? strings.t("badge.workspace").arg(Model.workspaceBadge(current.workspaceId))
                : (shownAt < 9 ? String(shownAt + 1) : "")

              onCapturedChanged: {
                var next = Object.assign({}, root.captured)
                next[modelData.address] = captured
                root.captured = next
              }
              onPointed: if (inView) root.selected = shownAt
              onActivated: if (inView) root.focusWindow(current)
              onCloseRequested: root.closeWindow(current)
              onDragMoved: (at) => { root.dropTarget = win.dropTargetAt(at) }
              onDropped: (at) => {
                var id = win.dropTargetAt(at)
                root.dropTarget = -1
                if (id === 0) id = root.newWorkspaceId
                if (id > 0) root.moveWindow(current, id)
              }
            }
          }

          Text {
            anchors.centerIn: grid
            visible: win.here && root.shown.length === 0
            opacity: win.late
            textFormat: Text.PlainText
            text: root.across ? strings.t("empty.filter") : strings.t("empty.workspace")
            color: win.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }

          // ---- Header ----

          Item {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.space(32)
            anchors.rightMargin: Style.space(32)
            anchors.topMargin: Style.space(12)
            height: Style.space(32)
            opacity: win.late
            visible: opacity > 0
            z: 3000
            transform: Translate { y: -Style.space(18) * (1 - win.late) }

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                text: strings.t("title")
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.weight: Font.Bold
              }

              Text {
                textFormat: Text.PlainText
                visible: root.appKey !== "" || root.query === ""
                text: root.appKey !== "" ? (root.names[root.appKey] || root.appKey)
                  : strings.t("workspace").arg(Model.workspaceBadge(root.workspaceId))
                color: root.appKey !== "" ? Color.foreground : win.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }

              Text {
                textFormat: Text.PlainText
                text: {
                  var count = strings.tn("count.windows", root.shown.length).arg(Commons.I18n.formatNumber(root.shown.length))
                  if (!root.across) return count
                  var spaces = strings.tn("count.workspaces", root.workspaceCount).arg(Commons.I18n.formatNumber(root.workspaceCount))
                  return strings.t("summary.across").arg(count).arg(spaces)
                }
                color: win.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }
            }

            // Filter: / to start typing, esc to leave it.
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "/"
                color: filter.activeFocus || root.across ? Color.accent : win.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }

              Rectangle {
                width: Style.space(280)
                height: Style.space(30)
                color: Util.alpha(Color.background, 0.7)
                border.width: 1
                border.color: filter.activeFocus || root.across ? Color.accent : Util.alpha(Color.foreground, 0.18)

                TextInput {
                  id: filter
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: Color.foreground
                  selectionColor: Util.alpha(Color.accent, 0.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  // Shows the app's name in app mode and the query otherwise,
                  // so the box always says what is being shown.
                  property bool mirroring: false

                  function sync() {
                    var want = root.appKey !== "" ? (root.names[root.appKey] || root.appKey) : root.query
                    if (text === want) return
                    mirroring = true
                    text = want
                    mirroring = false
                  }
                  onTextChanged: if (!mirroring) root.setQuery(text)

                  Connections {
                    target: root
                    function onQueryChanged() { filter.sync() }
                    function onAppKeyChanged() { filter.sync() }
                  }

                  Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape) {
                      if (text !== "") text = ""
                      else root.back()
                      keys.forceActiveFocus()
                    }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.focusWindow(root.selectedWindow)
                    else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) root.selected = Model.cycle(root.selected, root.shown.length, 1)
                    else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) root.selected = Model.cycle(root.selected, root.shown.length, -1)
                    else return
                    event.accepted = true
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: filter.text === ""
                    textFormat: Text.PlainText
                    text: strings.t("filter.placeholder")
                    color: win.muted
                    font: filter.font
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.IBeamCursor
                  onClicked: filter.forceActiveFocus()
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Repeater {
                model: root.across
                  ? [["tab", "hint.nextApp"], ["enter", "hint.focus"], ["q", "hint.close"], ["esc", "hint.allWindows"]]
                  : [["1–9", "hint.jump"], ["⇧1–9", "hint.send"], ["drag", "hint.drag"], ["q", "hint.close"], ["/", "hint.filter"], ["esc", "hint.back"]]

                Row {
                  required property var modelData
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData[0]
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: strings.t(modelData[1])
                    color: win.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }

          // ---- Dock ----

          // Rises from below the bottom edge as the desktop zooms out.
          AppDock {
            id: dock
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(20)
            width: Math.min(implicitWidth, parent.width - 2 * Style.space(48))
            height: implicitHeight
            z: 3000
            apps: win.here ? root.apps : []
            activeKey: root.activeAppKey
            iconFor: function(appId) { return root.appIcon(appId) }
            nameFor: function(appId) { return root.appName(appId) }
            opacity: Math.min(1, win.p * 1.6)
            transform: Translate { y: (dock.height + Style.space(40)) * (1 - win.p) }
            // Click: go to the app (its most recent window, wherever it is).
            onPicked: (app) => root.focusWindow(Model.mostRecent(app.windows))
            // Right-click: all of its windows, on every workspace.
            onExpanded: (app) => {
              if (root.appKey === app.key) root.back()
              else root.showApp(app.key)
              keys.forceActiveFocus()
            }
          }
        }

        // ---- Keys ----

        Item {
          id: keys
          anchors.fill: parent
          focus: true

          Keys.onPressed: (event) => {
            if (root.closing) return
            if (event.modifiers & Qt.ShiftModifier) {
              var target = Model.workspaceFromScanCode(event.nativeScanCode)
              if (target > 0) {
                root.moveWindow(root.selectedWindow, target)
                event.accepted = true
                return
              }
            }
            if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
              root.stepWorkspace(event.key === Qt.Key_Right ? 1 : -1)
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
              root.stepWorkspace(event.key === Qt.Key_PageDown ? 1 : -1)
              event.accepted = true
              return
            }
            var jump = Model.digitIndex(event.text)
            if (jump >= 0 && !(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier))) {
              if (jump < root.shown.length) root.focusWindow(root.shown[jump])
            }
            else if (event.key === Qt.Key_Escape) root.back()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) root.focusWindow(root.selectedWindow)
            else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) root.selected = Model.stepSelection(win.slots, root.selected, "left")
            else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) root.selected = Model.stepSelection(win.slots, root.selected, "right")
            else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) root.selected = Model.stepSelection(win.slots, root.selected, "up")
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) root.selected = Model.stepSelection(win.slots, root.selected, "down")
            else if (event.key === Qt.Key_Tab) root.stepApp(1)
            else if (event.key === Qt.Key_Backtab) root.stepApp(-1)
            else if (event.key === Qt.Key_Q || event.key === Qt.Key_X) root.closeWindow(root.selectedWindow)
            else if (event.key === Qt.Key_Slash) filter.forceActiveFocus()
            else return
            event.accepted = true
          }
        }
      }
    }
  }
}
