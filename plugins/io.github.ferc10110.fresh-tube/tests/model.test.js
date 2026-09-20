const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "FreshTubeModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Model = new Function(source + "\nreturn { relativeTime, formatClock, looksLikeChannelInput, playerArgs, playerName }")()

const NOW = Date.parse("2026-09-16T12:00:00Z")

test("relativeTime buckets", () => {
  assert.equal(Model.relativeTime("2026-09-16T11:59:40Z", NOW), "just now")
  assert.equal(Model.relativeTime("2026-09-16T11:55:00Z", NOW), "5 min ago")
  assert.equal(Model.relativeTime("2026-09-16T09:00:00Z", NOW), "3 h ago")
  assert.equal(Model.relativeTime("2026-09-15T08:00:00Z", NOW), "yesterday")
  assert.equal(Model.relativeTime("2026-09-12T12:00:00Z", NOW), "4 d ago")
  assert.equal(Model.relativeTime("2026-09-01T12:00:00Z", NOW), "Sep 1")
  assert.equal(Model.relativeTime("2026-09-16T13:00:00Z", NOW), "just now")
  assert.equal(Model.relativeTime("garbage", NOW), "")
  assert.equal(Model.relativeTime("", NOW), "")
  assert.equal(Model.relativeTime(null, NOW), "")
})

test("formatClock is hh:mm local", () => {
  const stamp = new Date(2026, 8, 16, 9, 5).toISOString()
  assert.equal(Model.formatClock(stamp), "09:05")
  assert.equal(Model.formatClock("nope"), "")
})

test("looksLikeChannelInput", () => {
  for (const good of ["https://www.youtube.com/@LinusTechTips", "youtube.com/c/x", "@handle",
                      "UCXuqSBlHAE6Xw-yeJA0Tunw", "https://youtu.be/abc", "  @spaced  "])
    assert.ok(Model.looksLikeChannelInput(good), good)
  for (const bad of ["", "  ", "two words", "https://vimeo.com/x", "UCshort", null])
    assert.ok(!Model.looksLikeChannelInput(bad), String(bad))
})

test("playerArgs and playerName", () => {
  assert.deepEqual(Model.playerArgs("mpv"), ["mpv"])
  assert.deepEqual(Model.playerArgs("  mpv --profile=yt  --mute "), ["mpv", "--profile=yt", "--mute"])
  assert.deepEqual(Model.playerArgs(""), ["mpv"])
  assert.deepEqual(Model.playerArgs(undefined), ["mpv"])
  assert.equal(Model.playerName("mpv --x"), "mpv")
  assert.equal(Model.playerName(null), "mpv")
})
