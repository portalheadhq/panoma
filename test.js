// node test.js — checks Exposé's snapshot, layout, filter, grouping and
// selection rules.
const assert = require("assert")
const Model = require("./Model.js")

const client = (address, cls, ws, at, size, focus, extra) => Object.assign({
  address, class: cls, title: cls + " window", workspace: { id: ws }, monitor: 0,
  at, size, focusHistoryID: focus, mapped: true, hidden: false, floating: false
}, extra || {})

const clients = [
  client("0xb", "chromium", 3, [960, 40], [940, 1000], 2),
  client("0xa", "nvim", 3, [10, 40], [940, 1000], 0),
  client("0xc", "com.mitchellh.ghostty", 1, [10, 40], [1900, 1000], 1),
  client("0xd", "spotify", -98, [10, 40], [1900, 1000], 4),
  client("0xe", "ghost", 3, [0, 0], [0, 0], 5),
  client("0xf", "hidden", 3, [0, 0], [800, 600], 6, { hidden: true }),
  client("0x10", "unmapped", 3, [0, 0], [800, 600], 7, { mapped: false })
]

// ---- snapshot ----
const windows = Model.snapshotWindows(clients)
assert.deepStrictEqual(windows.map((w) => w.address), ["0xc", "0xa", "0xb", "0xd"],
  "workspace order, then reading order; special last; zero-size, hidden and unmapped dropped")
assert.strictEqual(windows[0].appKey, "com.mitchellh.ghostty")
assert.strictEqual(windows[1].width, 940)
assert.deepStrictEqual(Model.snapshotWindows(null), [])
assert.deepStrictEqual(Model.onWorkspace(windows, 3).map((w) => w.address), ["0xa", "0xb"])

// ---- addresses ----
assert.strictEqual(Model.normalizeAddress("0x55D0ab"), "55d0ab")
assert.strictEqual(Model.normalizeAddress("55d0ab"), "55d0ab")
assert.strictEqual(Model.workspaceBadge(-98), "S")
assert.strictEqual(Model.workspaceBadge(4), "4")

// ---- filter ----
const names = { "com.mitchellh.ghostty": "Ghostty" }
assert.deepStrictEqual(Model.filterWindows(windows, "").length, 4)
assert.deepStrictEqual(Model.filterWindows(windows, "ghostty").map((w) => w.address), ["0xc"], "matches the app name")
assert.deepStrictEqual(Model.filterWindows(windows, "  WINDOW chrom ").map((w) => w.address), ["0xb"], "every word, any order, any case")
assert.deepStrictEqual(Model.filterWindows(windows, "zzz"), [])
// A title shaped like markup is just text to the filter.
const sneaky = Model.snapshotWindows([client("0x1", "x", 1, [0, 0], [10, 10], 0, { title: "<img src=x>" })])
assert.strictEqual(Model.filterWindows(sneaky, "<img").length, 1)

// ---- apps ----
const apps = Model.groupApps(windows.concat(Model.snapshotWindows([client("0x20", "chromium", 4, [0, 0], [500, 500], 3)])), 3)
assert.deepStrictEqual(apps.map((a) => a.key), ["com.mitchellh.ghostty", "chromium", "nvim", "spotify"])
const chromium = apps[1]
assert.strictEqual(chromium.count, 2)
assert.strictEqual(chromium.onWorkspace, true)
assert.strictEqual(apps[0].onWorkspace, false)
assert.strictEqual(Model.mostRecent(chromium.windows).address, "0xb")
assert.strictEqual(Model.mostRecent([]), null)

// ---- layout ----
assert.deepStrictEqual(Model.rowCounts(5, 2), [3, 2])
assert.deepStrictEqual(Model.rowCounts(4, 3), [2, 1, 1])

const area = { x: 0, y: 0, width: 1400, height: 700 }
assert.deepStrictEqual(Model.layoutRows([], area, 32, 0), [])

// One window: capped by the row height, centred.
const one = Model.layoutRows([{ width: 1600, height: 900 }], area, 32, 400)
assert.strictEqual(one.length, 1)
assert.strictEqual(one[0].height, 400)
assert.strictEqual(Math.round(one[0].x + one[0].width / 2), 700)
assert.strictEqual(Math.round(one[0].y + one[0].height / 2), 350)

// Five 16:9 windows: two rows (3 + 2), everything inside the area, aspect kept.
const five = Model.layoutRows(Array(5).fill({ width: 1600, height: 900 }), area, 32, 0)
assert.strictEqual(five.length, 5)
assert.strictEqual(five[0].y, five[2].y)
assert.ok(five[3].y > five[0].y)
for (const s of five) {
  assert.ok(s.x >= 0 && s.y >= 0 && s.x + s.width <= 1401 && s.y + s.height <= 701, JSON.stringify(s))
  assert.ok(Math.abs(s.width / s.height - 16 / 9) < 0.02)
}
// No overlaps.
for (let i = 0; i < five.length; i++)
  for (let j = i + 1; j < five.length; j++) {
    const a = five[i], b = five[j]
    assert.ok(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y)
  }

// A sliver of a window still gets a readable tile: a quarter of the height.
const sliver = Model.layoutRows([{ width: 5000, height: 10 }], area, 32, 0)
assert.ok(sliver[0].height >= 700 / 4 - 1, JSON.stringify(sliver[0]))
assert.ok(sliver[0].width <= 4 * sliver[0].height + 1, "aspect still clamped to 4:1")

// ---- selection ----
// five: row 0 = 0 1 2, row 1 = 3 4
assert.strictEqual(Model.stepSelection(five, 0, "right"), 1)
assert.strictEqual(Model.stepSelection(five, 2, "right"), 2, "stays at the edge")
assert.strictEqual(Model.stepSelection(five, 1, "down") === 3 || Model.stepSelection(five, 1, "down") === 4, true)
assert.strictEqual(Model.stepSelection(five, 3, "up") <= 2, true)
assert.strictEqual(Model.stepSelection(five, -1, "left"), 0)
assert.strictEqual(Model.stepSelection([], 0, "left"), -1)

assert.strictEqual(Model.cycle(2, 3, 1), 0)
assert.strictEqual(Model.cycle(0, 3, -1), 2)
assert.strictEqual(Model.cycle(-1, 3, -1), 2)
assert.strictEqual(Model.cycle(0, 0, 1), -1)

assert.strictEqual(Model.digitIndex("1"), 0)
assert.strictEqual(Model.digitIndex("9"), 8)
assert.strictEqual(Model.digitIndex("0"), -1)
assert.strictEqual(Model.digitIndex("a"), -1)
assert.strictEqual(Model.digitIndex(""), -1)

// ---- motion ----
const monitors = [
  { name: "HDMI-A-1", x: 1600, y: 0, reserved: [0, 0, 0, 0], focused: false },
  { name: "eDP-1", x: 0, y: 0, reserved: [0, 26, 0, 0], focused: true }
]
assert.deepStrictEqual(Model.monitorOffset(monitors, "eDP-1"), { x: 0, y: 26 })
assert.deepStrictEqual(Model.monitorOffset(monitors, "HDMI-A-1"), { x: 1600, y: 0 })
assert.deepStrictEqual(Model.monitorOffset(monitors, "nope"), { x: 0, y: 26 }, "falls back to the focused one")
assert.deepStrictEqual(Model.monitorOffset(null, "x"), { x: 0, y: 0 })
assert.deepStrictEqual(Model.realRect({ x: 5, y: 31, width: 792, height: 964 }, { x: 0, y: 26 }),
  { x: 5, y: 5, width: 792, height: 964 })

const real = { x: 0, y: 0, width: 800, height: 600 }
const slot = { x: 400, y: 300, width: 400, height: 300 }
// Home window: exactly on its real place at 0, exactly in its slot at 1.
assert.deepStrictEqual(Model.tileFrame(real, slot, 0, true, 1, false), { rect: real, opacity: 1 })
assert.deepStrictEqual(Model.tileFrame(real, slot, 1, true, 1, false), { rect: slot, opacity: 1 })
assert.deepStrictEqual(Model.tileFrame(real, slot, 0.5, true, 1, false).rect, { x: 200, y: 150, width: 600, height: 450 })
// Filtered out: invisible in the overview, but back in place on the desktop.
assert.strictEqual(Model.tileFrame(real, slot, 1, true, 0, false).opacity, 0)
assert.strictEqual(Model.tileFrame(real, slot, 0, true, 0, false).opacity, 1)
// Another workspace's window only exists in the overview.
assert.strictEqual(Model.tileFrame(real, slot, 0, false, 1, false).opacity, 0)
assert.deepStrictEqual(Model.tileFrame(real, slot, 1, false, 1, false), { rect: slot, opacity: 1 })
// Closed windows never come back, whatever the progress.
assert.strictEqual(Model.tileFrame(real, slot, 0, true, 1, true).opacity, 0)
// Progress outside 0–1 (an overshooting finger) is clamped.
assert.deepStrictEqual(Model.tileFrame(real, slot, 1.4, true, 1, false).rect, slot)

assert.strictEqual(Model.releaseTarget(0.2, 2), 1, "flick up opens")
assert.strictEqual(Model.releaseTarget(0.9, -2), 0, "flick down closes")
assert.strictEqual(Model.releaseTarget(0.6, 0), 1)
assert.strictEqual(Model.releaseTarget(0.4, 0.1), 0)

// ---- swipe reader ----
assert.deepStrictEqual(Model.parseSwipeLine("-event7   GESTURE_SWIPE_BEGIN     +3.456s\t3"),
  { type: "begin", fingers: 3, dx: 0, dy: 0, cancelled: false })
assert.deepStrictEqual(Model.parseSwipeLine(" event7   GESTURE_SWIPE_UPDATE    +3.462s\t3  0.21/-1.94 ( 0.35/-3.22 unaccelerated)"),
  { type: "update", fingers: 3, dx: 0.21, dy: -1.94, cancelled: false })
assert.deepStrictEqual(Model.parseSwipeLine(" event7   GESTURE_SWIPE_UPDATE    +3.462s\t4 -12.00/ 3.50 (-20.00/ 5.80 unaccelerated)"),
  { type: "update", fingers: 4, dx: -12, dy: 3.5, cancelled: false })
// Real lines from this touchpad: repeats carry a count before the timestamp.
assert.deepStrictEqual(Model.parseSwipeLine(" event9   GESTURE_SWIPE_UPDATE      2  +1.676s\t3  1.24/-6.22 ( 1.24/-6.22 unaccelerated)"),
  { type: "update", fingers: 3, dx: 1.24, dy: -6.22, cancelled: false })
assert.deepStrictEqual(Model.parseSwipeLine(" event9   GESTURE_SWIPE_BEGIN          +1.662s\t3"),
  { type: "begin", fingers: 3, dx: 0, dy: 0, cancelled: false })
assert.strictEqual(Model.parseSwipeLine(" event9   GESTURE_HOLD_END             +1.662s\t3 cancelled"), null)
assert.strictEqual(Model.parseSwipeLine(" event7   GESTURE_SWIPE_END       +3.520s\t3 cancelled").cancelled, true)
assert.strictEqual(Model.parseSwipeLine(" event7   GESTURE_SWIPE_END       +3.520s\t3").cancelled, false)
assert.strictEqual(Model.parseSwipeLine(" event7   POINTER_MOTION          +3.520s\t 1.00/ 2.00"), null)
assert.strictEqual(Model.parseSwipeLine(" event7   GESTURE_PINCH_BEGIN     +3.520s\t3"), null)
assert.strictEqual(Model.parseSwipeLine(""), null)
assert.strictEqual(Model.swipeAxis(3, 4, 10), "")
assert.strictEqual(Model.swipeAxis(2, -11, 10), "vertical")
assert.strictEqual(Model.swipeAxis(-15, 6, 10), "horizontal")

// ---- bigger, never upscaled ----
const big = { x: 0, y: 0, width: 3000, height: 2000 }
const natural = Model.layoutRows([{ width: 800, height: 600 }], big, 24, 0)
assert.strictEqual(natural[0].height, 600, "a window is never shown bigger than it is")
const pair = Model.layoutRows([{ width: 792, height: 964 }, { width: 792, height: 964 }], { x: 0, y: 0, width: 1536, height: 650 }, 24, 650)
assert.strictEqual(pair[0].height, 650, "two tall windows fill the height")
assert.strictEqual(pair[0].y, pair[1].y)

// ---- workspaces ----
const wsWins = [
  { address: "a", workspaceId: 1 }, { address: "b", workspaceId: 3 },
  { address: "c", workspaceId: 3 }, { address: "d", workspaceId: -98 }
]
const strip = Model.workspaceStrip([2, 1, -98, 5], wsWins, 4)
assert.deepStrictEqual(strip.map((w) => w.id), [1, 2, 3, 4, 5], "Hyprland's, windows', and the current; no specials")
assert.deepStrictEqual(strip[2].windows.map((w) => w.address), ["b", "c"])
assert.strictEqual(strip[3].current, true)
assert.strictEqual(strip[0].current, false)
assert.deepStrictEqual(Model.workspaceStrip(null, [], 1).map((w) => w.id), [1])

assert.strictEqual(Model.nextFreeWorkspace([1, 2, 3, 5]), 4)
assert.strictEqual(Model.nextFreeWorkspace([2, 3]), 1)
assert.strictEqual(Model.nextFreeWorkspace([]), 1)

assert.strictEqual(Model.workspaceFromScanCode(10), 1, "the 1 key")
assert.strictEqual(Model.workspaceFromScanCode(18), 9, "the 9 key")
assert.strictEqual(Model.workspaceFromScanCode(19), -1, "the 0 key")
assert.strictEqual(Model.workspaceFromScanCode(24), -1, "q")

const moved = Model.withWorkspace(wsWins, "a", 3)
assert.strictEqual(moved[0].workspaceId, 3)
assert.strictEqual(wsWins[0].workspaceId, 1, "the original is left alone")
assert.strictEqual(moved[1], wsWins[1], "other windows keep their identity")

// ---- borders & neighbours ----
assert.strictEqual(Model.parseBorderColor("ffff9f0a 0deg", "#000"), "#ffff9f0a")
assert.strictEqual(Model.parseBorderColor("aa595959 0deg", "#000"), "#aa595959")
assert.strictEqual(Model.parseBorderColor("rgba(1,2,3)", "#000"), "#000")
assert.strictEqual(Model.parseBorderColor(undefined, "#111"), "#111")

assert.strictEqual(Model.neighborWorkspace([1, 2, 3, 5], 3, 1, true), 5, "skips gaps in the strip")
assert.strictEqual(Model.neighborWorkspace([1, 2, 3, 5], 3, -1, true), 2)
assert.strictEqual(Model.neighborWorkspace([1, 2, 3], 1, -1, true), -1, "nothing left of the first")
assert.strictEqual(Model.neighborWorkspace([1, 2, 3], 3, 1, true), 4, "a fresh one past the last")
assert.strictEqual(Model.neighborWorkspace([1, 2, 3], 3, 1, false), -1, "but not from an empty one")
assert.strictEqual(Model.neighborWorkspace([2, 4], 3, 1, true), 4, "current missing from the strip still finds its place")

console.log("ok")
