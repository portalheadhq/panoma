// Pure logic for Panoma: turning `hyprctl -j clients` into the windows the
// overlay shows, laying them out, filtering, grouping by app and moving the
// selection. No QML in here, so `node test.js` can check all of it.

// Web apps all report as chrome-<host>__…, which no desktop entry is named
// after; the host is what finds their launcher.
function webAppHost(appId) {
  var match = String(appId || "").match(/^chrome-([^_\/]+)__/)
  return match ? match[1].toLowerCase() : ""
}

// hyprctl prints "0x55d0…", Quickshell's HyprlandToplevel.address may not
// carry the prefix; compare them without it.
function normalizeAddress(address) {
  return String(address || "").toLowerCase().replace(/^0x/, "")
}

function workspaceBadge(id) {
  return id < 0 ? "S" : String(id)
}

// Special workspaces (negative ids) sort after the numbered ones.
function workspaceOrder(id) {
  return id < 0 ? 100000 - id : id
}

// The windows Panoma knows about, newest focus first within a workspace and
// in on-screen reading order otherwise. Unmapped and hidden windows are left
// out; so is anything without a size to draw.
function snapshotWindows(clients) {
  var list = []
  var source = Array.isArray(clients) ? clients : []
  for (var i = 0; i < source.length; i++) {
    var c = source[i]
    if (!c || c.mapped === false || c.hidden === true) continue
    var size = Array.isArray(c.size) ? c.size : [0, 0]
    var at = Array.isArray(c.at) ? c.at : [0, 0]
    if (!(size[0] > 0 && size[1] > 0)) continue
    var appId = String(c["class"] || c.initialClass || "")
    list.push({
      address: String(c.address || ""),
      appId: appId,
      appKey: appId.toLowerCase(),
      title: String(c.title || ""),
      workspaceId: c.workspace ? Number(c.workspace.id) : 0,
      monitor: typeof c.monitor === "number" ? c.monitor : -1,
      x: Number(at[0]) || 0,
      y: Number(at[1]) || 0,
      width: Number(size[0]),
      height: Number(size[1]),
      floating: c.floating === true,
      focusHistoryId: typeof c.focusHistoryID === "number" ? c.focusHistoryID : 9999
    })
  }
  list.sort(function(a, b) {
    var ws = workspaceOrder(a.workspaceId) - workspaceOrder(b.workspaceId)
    if (ws !== 0) return ws
    if (a.y !== b.y) return a.y - b.y
    if (a.x !== b.x) return a.x - b.x
    return a.focusHistoryId - b.focusHistoryId
  })
  return list
}

function onWorkspace(windows, workspaceId) {
  return windows.filter(function(w) { return w.workspaceId === workspaceId })
}

// Case-insensitive match on app id, app name and title. Every word typed has
// to appear somewhere, in any order. `names` maps appKey → display name.
function filterWindows(windows, query, names) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
  if (words.length === 0) return windows.slice()
  return windows.filter(function(w) {
    var name = names && names[w.appKey] ? String(names[w.appKey]) : ""
    var haystack = (w.appId + " " + name + " " + w.title).toLowerCase()
    return words.every(function(word) { return haystack.indexOf(word) !== -1 })
  })
}

// One entry per app, in the order the dock shows them: by the lowest
// workspace the app has a window on, then by name. `count` is how many
// windows it has, `onWorkspace` whether one of them is on `currentWorkspace`.
function groupApps(windows, currentWorkspace) {
  var byKey = {}
  var apps = []
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    if (!w.appKey) continue
    var app = byKey[w.appKey]
    if (!app) {
      app = { key: w.appKey, appId: w.appId, windows: [], count: 0, workspaceId: w.workspaceId, onWorkspace: false, recent: w.focusHistoryId }
      byKey[w.appKey] = app
      apps.push(app)
    }
    app.windows.push(w)
    app.count++
    if (workspaceOrder(w.workspaceId) < workspaceOrder(app.workspaceId)) app.workspaceId = w.workspaceId
    if (w.workspaceId === currentWorkspace) app.onWorkspace = true
    if (w.focusHistoryId < app.recent) app.recent = w.focusHistoryId
  }
  apps.sort(function(a, b) {
    var ws = workspaceOrder(a.workspaceId) - workspaceOrder(b.workspaceId)
    return ws !== 0 ? ws : (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)
  })
  return apps
}

// The app whose windows are most recently focused within a group.
function mostRecent(windows) {
  var best = null
  for (var i = 0; i < windows.length; i++)
    if (!best || windows[i].focusHistoryId < best.focusHistoryId) best = windows[i]
  return best
}

// Splits n items into r rows as evenly as possible, earlier rows taking the
// extra one: 5 into 2 → [3, 2].
function rowCounts(n, r) {
  var counts = []
  var base = Math.floor(n / r)
  var extra = n % r
  for (var i = 0; i < r; i++) counts.push(base + (i < extra ? 1 : 0))
  return counts
}

// Justified rows. Each window keeps its aspect ratio; every window in a row
// shares the row's height, and the row fills the width unless that would
// make it taller than `maxRowHeight`, or than the shortest window in it
// really is: the overview never blows a window up past its real size. The row count is whichever gives the
// windows the most total area once the whole block fits `area`.
// Returns one slot per window, in input order: { x, y, width, height }.
function layoutRows(sizes, area, gap, maxRowHeight) {
  var n = sizes.length
  if (n === 0 || !(area.width > 0) || !(area.height > 0)) return []
  var cap = maxRowHeight > 0 ? maxRowHeight : area.height
  var aspects = sizes.map(function(s) {
    var a = s.width > 0 && s.height > 0 ? s.width / s.height : 16 / 9
    return Math.min(4, Math.max(0.25, a))
  })

  var best = null
  for (var r = 1; r <= n; r++) {
    var counts = rowCounts(n, r)
    var rows = []
    var start = 0
    var total = gap * (r - 1)
    for (var i = 0; i < r; i++) {
      var sum = 0
      for (var k = start; k < start + counts[i]; k++) sum += aspects[k]
      var natural = Infinity
      for (var q0 = start; q0 < start + counts[i]; q0++)
        if (sizes[q0].height > 0) natural = Math.min(natural, sizes[q0].height)
      // Small windows may grow to a readable size, up to a quarter of the area.
      natural = Math.max(natural, Math.min(cap, area.height * 0.25))
      var h = Math.min(cap, natural, (area.width - gap * (counts[i] - 1)) / sum)
      rows.push({ start: start, count: counts[i], sum: sum, height: h })
      total += h
      start += counts[i]
    }
    var scale = Math.min(1, (area.height - gap * (r - 1)) / (total - gap * (r - 1)))
    var covered = 0
    for (var j = 0; j < rows.length; j++) {
      var hh = rows[j].height * scale
      covered += hh * hh * rows[j].sum
    }
    if (!best || covered > best.covered + 0.5) best = { rows: rows, scale: scale, covered: covered }
    // More rows only shrink things once every row already fills the width.
    if (scale < 0.5) break
  }

  var slots = new Array(n)
  var blockHeight = gap * (best.rows.length - 1)
  for (var m = 0; m < best.rows.length; m++) blockHeight += best.rows[m].height * best.scale
  var y = area.y + (area.height - blockHeight) / 2
  for (var q = 0; q < best.rows.length; q++) {
    var row = best.rows[q]
    var rh = row.height * best.scale
    var rowWidth = rh * row.sum + gap * (row.count - 1)
    var x = area.x + (area.width - rowWidth) / 2
    for (var z = row.start; z < row.start + row.count; z++) {
      var w = rh * aspects[z]
      slots[z] = { x: Math.round(x), y: Math.round(y), width: Math.round(w), height: Math.round(rh) }
      x += w + gap
    }
    y += rh + gap
  }
  return slots
}

// Moves the selection to the nearest slot in a direction ("left", "right",
// "up", "down"), judged from slot centres. Left/right prefer the same row;
// stays put when nothing lies that way.
function stepSelection(slots, current, direction) {
  if (slots.length === 0) return -1
  if (current < 0 || current >= slots.length) return 0
  var from = slots[current]
  var fx = from.x + from.width / 2
  var fy = from.y + from.height / 2
  var best = -1
  var bestScore = Infinity
  for (var i = 0; i < slots.length; i++) {
    if (i === current) continue
    var s = slots[i]
    var dx = s.x + s.width / 2 - fx
    var dy = s.y + s.height / 2 - fy
    var along, across
    if (direction === "left") { along = -dx; across = Math.abs(dy) }
    else if (direction === "right") { along = dx; across = Math.abs(dy) }
    else if (direction === "up") { along = -dy; across = Math.abs(dx) }
    else if (direction === "down") { along = dy; across = Math.abs(dx) }
    else return current
    if (along <= 1) continue
    var score = along + across * 2
    if (score < bestScore) { bestScore = score; best = i }
  }
  return best < 0 ? current : best
}

function cycle(index, n, step) {
  if (n <= 0) return -1
  if (index < 0) return step > 0 ? 0 : n - 1
  return ((index + step) % n + n) % n
}

// Digit keys 1–9 pick a window; anything else is not a jump.
function digitIndex(text) {
  var c = String(text || "")
  return c.length === 1 && c >= "1" && c <= "9" ? c.charCodeAt(0) - 49 : -1
}

// ---- Motion ------------------------------------------------------------------
// The overview is one number, progress: 0 is the desktop as it is, 1 the
// overview. Keys and taps animate it; a three-finger swipe drags it.

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v
}

function lerp(a, b, t) {
  return a + (b - a) * t
}

function lerpRect(a, b, t) {
  return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t) }
}

function scaleRect(r, s) {
  var w = r.width * s
  var h = r.height * s
  return { x: r.x + (r.width - w) / 2, y: r.y + (r.height - h) / 2, width: w, height: h }
}

// The focused monitor out of `hyprctl -j monitors`, as what windows' global
// positions need taking off them to land in the overlay: its origin plus the
// space the bar reserves (reserved is [left, top, right, bottom]).
function monitorOffset(monitors, name) {
  var list = Array.isArray(monitors) ? monitors : []
  var m = null
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === name) m = list[i]
  if (!m) for (var j = 0; j < list.length; j++) if (list[j] && list[j].focused) m = list[j]
  if (!m) return { x: 0, y: 0 }
  var r = Array.isArray(m.reserved) ? m.reserved : [0, 0, 0, 0]
  return { x: (Number(m.x) || 0) + (Number(r[0]) || 0), y: (Number(m.y) || 0) + (Number(r[1]) || 0) }
}

// Where the window really is, in overlay coordinates.
function realRect(w, offset) {
  return { x: w.x - offset.x, y: w.y - offset.y, width: w.width, height: w.height }
}

// How a tile is drawn at a given progress.
//   home   the window is on the workspace the desktop shows at progress 0,
//          so it morphs out of its real place
//   shown  0–1, how much it belongs to what the overview shows now
//          (animated, so filtering fades rather than pops)
//   gone   closed from the overview: never drawn again
function tileFrame(real, slot, progress, home, shown, gone) {
  var p = clamp01(progress)
  if (gone) return { rect: slot, opacity: 0 }
  var settle = 0.92 + 0.08 * shown
  if (home) return { rect: lerpRect(real, scaleRect(slot, settle), p), opacity: 1 - p * (1 - shown) }
  return { rect: scaleRect(slot, settle * (0.92 + 0.08 * p)), opacity: p * shown }
}

// Where a released swipe settles: a flick decides by its direction, a slow
// drag by how far it got. Velocity is in progress per second.
function releaseTarget(progress, velocity) {
  if (velocity > 0.8) return 1
  if (velocity < -0.8) return 0
  return progress >= 0.5 ? 1 : 0
}

// One line of `libinput debug-events` → a swipe event, or null for anything
// else. Deltas are the accelerated ones; negative dy is fingers moving up.
//    event7  GESTURE_SWIPE_BEGIN   +3.456s  3
//    event7  GESTURE_SWIPE_UPDATE  +3.462s  3  0.21/-1.94 ( 0.35/-3.22 unaccelerated)
//    event7  GESTURE_SWIPE_UPDATE 2 +3.469s  3  1.24/-6.22 ( 1.24/-6.22 unaccelerated)
//    event7  GESTURE_SWIPE_END     +3.520s  3 cancelled
function parseSwipeLine(line) {
  // An optional repeat count sits between the event name and the timestamp.
  var m = String(line || "").match(/GESTURE_SWIPE_(BEGIN|UPDATE|END)\s+(?:\d+\s+)?\+[\d.]+s\s+(\d+)(.*)$/)
  if (!m) return null
  var event = { type: m[1].toLowerCase(), fingers: Number(m[2]), dx: 0, dy: 0, cancelled: false }
  if (event.type === "update") {
    var d = m[3].match(/(-?\d+(?:\.\d+)?)\s*\/\s*(-?\d+(?:\.\d+)?)/)
    if (!d) return null
    event.dx = Number(d[1])
    event.dy = Number(d[2])
  } else if (event.type === "end") {
    event.cancelled = /cancel/.test(m[3])
  }
  return event
}

// Which way a swipe is going once it has travelled `threshold`: "", not yet.
function swipeAxis(dx, dy, threshold) {
  if (Math.abs(dx) < threshold && Math.abs(dy) < threshold) return ""
  return Math.abs(dy) >= Math.abs(dx) ? "vertical" : "horizontal"
}

// ---- Workspaces ----------------------------------------------------------------

// The workspace strip: every numbered workspace on this monitor (ids from
// Hyprland), every one a window is on, and the current one, in order, each
// with its windows. Special workspaces (negative ids) stay out of it.
function workspaceStrip(ids, windows, current) {
  var seen = {}
  var list = []
  function add(id) {
    id = Number(id)
    if (!(id > 0) || seen[id]) return
    seen[id] = true
    list.push(id)
  }
  ;(Array.isArray(ids) ? ids : []).forEach(add)
  ;(Array.isArray(windows) ? windows : []).forEach(function(w) { add(w.workspaceId) })
  add(current)
  list.sort(function(a, b) { return a - b })
  return list.map(function(id) {
    return { id: id, current: id === current, windows: windows.filter(function(w) { return w.workspaceId === id }) }
  })
}

// The lowest workspace id nothing is using, for "new workspace".
function nextFreeWorkspace(ids) {
  var used = {}
  ;(Array.isArray(ids) ? ids : []).forEach(function(id) { used[Number(id)] = true })
  var id = 1
  while (used[id]) id++
  return id
}

// Shift+digit sends a window to a workspace. Shift turns the digit into a
// symbol that depends on the layout, so go by the physical key: evdev codes
// 2–10 are the 1–9 keys, which Wayland reports plus 8.
function workspaceFromScanCode(code) {
  var n = Number(code) - 9
  return n >= 1 && n <= 9 ? n : -1
}

// Moves a window to a workspace in a snapshot without touching the others.
function withWorkspace(windows, address, workspaceId) {
  return windows.map(function(w) {
    return w.address === address ? Object.assign({}, w, { workspaceId: workspaceId }) : w
  })
}

// Hyprland's border colours come back as "AARRGGBB 0deg" (a gradient of
// one); Qt reads "#AARRGGBB". Anything else falls back.
function parseBorderColor(gradient, fallback) {
  var m = String(gradient || "").match(/^\s*([0-9a-fA-F]{8})\b/)
  return m ? "#" + m[1].toLowerCase() : fallback
}

// The workspace next to `current` in the strip, `dir` +1 (right) or -1
// (left). Past the last one, right offers a fresh workspace (current + 1) if
// the current one has windows to leave; otherwise -1, nothing there.
function neighborWorkspace(stripIds, current, dir, currentHasWindows) {
  var ids = (Array.isArray(stripIds) ? stripIds : []).slice().sort(function(a, b) { return a - b })
  // The nearest id on that side, whether or not current is in the list.
  var best = -1
  for (var i = 0; i < ids.length; i++) {
    if (dir > 0 && ids[i] > current && (best < 0 || ids[i] < best)) best = ids[i]
    if (dir < 0 && ids[i] < current && ids[i] > 0 && (best < 0 || ids[i] > best)) best = ids[i]
  }
  if (best > 0) return best
  if (dir > 0 && currentHasWindows) {
    var id = current + 1
    while (ids.indexOf(id) !== -1) id++
    return id
  }
  return -1
}

if (typeof module !== "undefined") {
  module.exports = {
    webAppHost: webAppHost,
    normalizeAddress: normalizeAddress,
    workspaceBadge: workspaceBadge,
    workspaceOrder: workspaceOrder,
    snapshotWindows: snapshotWindows,
    onWorkspace: onWorkspace,
    filterWindows: filterWindows,
    groupApps: groupApps,
    mostRecent: mostRecent,
    rowCounts: rowCounts,
    layoutRows: layoutRows,
    stepSelection: stepSelection,
    cycle: cycle,
    digitIndex: digitIndex,
    clamp01: clamp01,
    lerpRect: lerpRect,
    scaleRect: scaleRect,
    monitorOffset: monitorOffset,
    realRect: realRect,
    tileFrame: tileFrame,
    releaseTarget: releaseTarget,
    parseSwipeLine: parseSwipeLine,
    swipeAxis: swipeAxis,
    workspaceStrip: workspaceStrip,
    nextFreeWorkspace: nextFreeWorkspace,
    workspaceFromScanCode: workspaceFromScanCode,
    withWorkspace: withWorkspace,
    parseBorderColor: parseBorderColor,
    neighborWorkspace: neighborWorkspace
  }
}
