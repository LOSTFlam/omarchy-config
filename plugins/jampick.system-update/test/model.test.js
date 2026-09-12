// Tests for Model.js. Pure functions, so plain Node with no framework.
//   node test/model.test.js
//
// The point of most of these is the intake: parseReport() is what stands
// between the scan's stdout and a QML Repeater, and a Repeater turns rows into
// delegates that live as long as the shell process does. So the caps get
// asserted here rather than assumed.

var assert = require("assert")
var fs = require("fs")
var path = require("path")

// Model.js is a QML library; `.pragma library` is not JavaScript Node accepts.
var source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
var box = { exports: {} }
new Function("module", source)(box)
var Model = box.exports

var passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
    console.log("  ok    " + name)
  } catch (e) {
    console.log("  FAIL  " + name + "\n          " + (e && e.message))
    process.exitCode = 1
  }
}

function pkg(name, extra) {
  var row = { name: name, from: "1.0", to: "1.1", repo: "extra", bytes: 100, tag: "" }
  var keys = Object.keys(extra || {})
  for (var i = 0; i < keys.length; i++) row[keys[i]] = extra[keys[i]]
  return row
}

function report(extra) {
  var doc = {
    ok: true, error: null, omarchy: null, dev: [],
    packages: [], aur: [], totalBytes: 0, restartCount: 0
  }
  var keys = Object.keys(extra || {})
  for (var i = 0; i < keys.length; i++) doc[keys[i]] = extra[keys[i]]
  return JSON.stringify(doc)
}

function many(n, prefix) {
  var out = []
  for (var i = 0; i < n; i++) out.push(pkg((prefix || "pkg") + i))
  return out
}

console.log("Model.parseReport")

// --- refusing what is not a document ---------------------------------------

test("nothing at all is not a document", function () {
  assert.strictEqual(Model.parseReport(""), null)
  assert.strictEqual(Model.parseReport(null), null)
  assert.strictEqual(Model.parseReport(undefined), null)
})

test("unparseable output is not a document", function () {
  assert.strictEqual(Model.parseReport("not json"), null)
  assert.strictEqual(Model.parseReport('{"ok":true'), null)
})

test("a bare array is not a document", function () {
  assert.strictEqual(Model.parseReport("[]"), null)
  assert.strictEqual(Model.parseReport('"a string"'), null)
})

test("output larger than the scan can print is refused before parsing", function () {
  var huge = '{"ok":true,"pad":"' + new Array(600 * 1024).join("x") + '"}'
  assert.strictEqual(Model.parseReport(huge), null)
})

// --- the row cap ------------------------------------------------------------

test("package rows are capped no matter what the document claims", function () {
  var doc = Model.parseReport(report({ packages: many(4000) }))
  assert.strictEqual(doc.packages.length, Model.MAX_ROWS.packages)
})

test("aur and dev rows are capped too", function () {
  var commits = []
  for (var i = 0; i < 500; i++) commits.push({ hash: "abc" + i, subject: "a commit" })
  var doc = Model.parseReport(report({ aur: many(900, "aurpkg"), dev: commits }))
  assert.strictEqual(doc.aur.length, Model.MAX_ROWS.aur)
  assert.strictEqual(doc.dev.length, Model.MAX_ROWS.dev)
})

test("a capped list reports how many it is not showing", function () {
  var doc = Model.parseReport(report({
    packages: many(300),
    counts: { packages: 300, aur: 0, dev: 0 },
    omitted: { packages: 50, aur: 0, dev: 0 }
  }))
  assert.strictEqual(doc.counts.packages, 300)
  assert.strictEqual(doc.omitted.packages, 300 - doc.packages.length)
})

test("the scan's own truncation is carried through, not recounted", function () {
  // The scan sends 250 rows and says there were 900. The panel must say 900.
  var doc = Model.parseReport(report({
    packages: many(250),
    counts: { packages: 900, aur: 0, dev: 0 }
  }))
  assert.strictEqual(doc.counts.packages, 900)
  assert.strictEqual(doc.omitted.packages, 650)
  assert.strictEqual(Model.packageCount(doc), 900)
})

test("a document that undercounts itself cannot hide rows", function () {
  var doc = Model.parseReport(report({ packages: many(10), counts: { packages: 2 } }))
  assert.strictEqual(doc.counts.packages, 10)
  assert.strictEqual(doc.omitted.packages, 0)
  assert.strictEqual(Model.omittedNote(doc), "")
})

test("a document with no counts at all is assumed complete", function () {
  var doc = Model.parseReport(report({ packages: many(3) }))
  assert.strictEqual(doc.counts.packages, 3)
  assert.strictEqual(doc.omitted.packages, 0)
})

// --- what a row is allowed to be -------------------------------------------

test("a row is reduced to the fields the panel draws", function () {
  var doc = Model.parseReport(report({
    packages: [pkg("vim", { evil: "payload", nested: { deep: true } })]
  }))
  assert.deepStrictEqual(Object.keys(doc.packages[0]).sort(),
    ["bytes", "from", "name", "repo", "tag", "to"])
})

test("a very long name is cut to something that can be read", function () {
  var doc = Model.parseReport(report({ packages: [pkg(new Array(9000).join("a"))] }))
  assert.ok(doc.packages[0].name.length <= 120, doc.packages[0].name.length + " chars")
})

test("control characters cannot reflow the panel", function () {
  var esc = String.fromCharCode(27)
  var bell = String.fromCharCode(7)
  var doc = Model.parseReport(report({
    packages: [pkg("vim" + esc + "[2Jclear", { repo: "ex" + bell + "tra" })]
  }))
  assert.strictEqual(doc.packages[0].name, "vim[2Jclear")
  assert.strictEqual(doc.packages[0].repo, "extra")
})

test("only the two tags the panel renders survive", function () {
  var doc = Model.parseReport(report({
    packages: [pkg("a", { tag: "reboot" }), pkg("b", { tag: "restart" }),
               pkg("c", { tag: "<b>own the panel</b>" }), pkg("d", { tag: 7 })]
  }))
  assert.deepStrictEqual(doc.packages.map(function (p) { return p.tag }),
    ["reboot", "restart", "", ""])
})

test("a nonsense byte count reads as zero, never as a negative size", function () {
  var doc = Model.parseReport(report({
    packages: [pkg("a", { bytes: -5 }), pkg("b", { bytes: "huge" }),
               pkg("c", { bytes: 1e999 })]
  }))
  assert.deepStrictEqual(doc.packages.map(function (p) { return p.bytes }), [0, 0, 0])
  assert.strictEqual(Model.rowMeta(doc.packages[0]), "extra")
})

test("a nameless row is dropped rather than drawn blank", function () {
  var doc = Model.parseReport(report({
    packages: [pkg("real"), { from: "1", to: "2" }, null, "not a row"]
  }))
  assert.strictEqual(doc.packages.length, 1)
  assert.strictEqual(doc.packages[0].name, "real")
})

test("lists that are not lists become empty ones", function () {
  var doc = Model.parseReport(report({ packages: "everything", aur: 42, dev: null }))
  assert.deepStrictEqual(doc.packages, [])
  assert.deepStrictEqual(doc.aur, [])
  assert.deepStrictEqual(doc.dev, [])
})

test("ok is only ever true when the document says so exactly", function () {
  assert.strictEqual(Model.parseReport(report({ ok: "yes" })).ok, false)
  assert.strictEqual(Model.parseReport(report({ ok: 1 })).ok, false)
  assert.strictEqual(Model.parseReport(report({ ok: true })).ok, true)
})

// --- markup, for the components whose textFormat this plugin does not own ---

test("angle brackets never reach a shared component", function () {
  var doc = Model.parseReport(report({
    omarchy: pkg("omarchy", { from: "2.0", to: "<img src=x>3.0" })
  }))
  var title = Model.heroTitle(doc, "")
  assert.strictEqual(title.indexOf("<"), -1, title)
  // The only > left is the panel's own arrow between the two versions.
  assert.strictEqual(title.split(">").length - 1, 1, title)
  assert.ok(title.indexOf("3.0") !== -1, title)
})

test("flattening the title does not eat the arrow between the versions", function () {
  var doc = Model.parseReport(report({ omarchy: pkg("omarchy", { from: "4.0.1-1", to: "4.0.2-1" }) }))
  assert.strictEqual(Model.heroTitle(doc, ""), "Omarchy 4.0.1-1 -> 4.0.2-1")
})

test("the availability summary is flattened before it becomes the title", function () {
  var title = Model.heroTitle(null, "<b>Omarchy 2.1</b>")
  assert.strictEqual(title.indexOf("<"), -1)
  assert.strictEqual(Model.heroTitle(null, ""), "System update")
})

test("an error sentence is flattened before it becomes a tooltip", function () {
  var doc = Model.parseReport(report({ ok: false, error: "Mirror <b>died</b>." }))
  var tip = Model.tooltip(doc, false)
  assert.strictEqual(tip.indexOf("<"), -1)
  assert.ok(tip.indexOf("died") !== -1, tip)
})

// --- the panel's own arithmetic --------------------------------------------

console.log("Model panel helpers")

test("the header counts omarchy alongside the packages", function () {
  var doc = Model.parseReport(report({
    omarchy: pkg("omarchy"), packages: many(4), aur: many(2, "aurpkg")
  }))
  assert.strictEqual(Model.packageCount(doc), 7)
  assert.strictEqual(Model.summary(doc).indexOf("7 packages"), 0)
})

test("one package is not 1 packages", function () {
  var doc = Model.parseReport(report({ packages: many(1) }))
  assert.strictEqual(Model.summary(doc).indexOf("1 package"), 0)
  assert.strictEqual(Model.summary(doc).indexOf("1 packages"), -1)
})

test("the omitted line is a sentence, and singular when it is one", function () {
  var one = Model.parseReport(report({ packages: many(2), counts: { packages: 3 } }))
  assert.ok(/^1 more package is not listed/.test(Model.omittedNote(one)), Model.omittedNote(one))
  assert.strictEqual(Model.omittedNote(one).slice(-1), ".")
  var lots = Model.parseReport(report({ packages: many(2), counts: { packages: 30 } }))
  assert.ok(/^28 more packages are not listed/.test(Model.omittedNote(lots)), Model.omittedNote(lots))
})

test("the omitted line counts dropped aur rows as well", function () {
  var doc = Model.parseReport(report({
    packages: many(2), aur: many(1, "aurpkg"),
    counts: { packages: 4, aur: 3 }
  }))
  assert.ok(/^4 more packages/.test(Model.omittedNote(doc)), Model.omittedNote(doc))
})

test("a reboot is still announced when it is the only tagged row", function () {
  var doc = Model.parseReport(report({
    packages: many(20).concat([pkg("linux", { tag: "reboot" })])
  }))
  assert.strictEqual(Model.needsReboot(doc), true)
})

test("sections put what restarts first and never lose a row", function () {
  var doc = Model.parseReport(report({
    packages: [pkg("linux", { tag: "reboot" }), pkg("zsh"), pkg("mesa", { tag: "restart" })],
    aur: [pkg("some-git")]
  }))
  var sections = Model.sections(doc)
  assert.deepStrictEqual(sections.map(function (s) { return s.title }),
    ["NEEDS A RESTART", "EVERYTHING ELSE", "AUR"])
  var rows = sections.reduce(function (n, s) { return n + s.rows.length }, 0)
  assert.strictEqual(rows, 4)
  assert.strictEqual(sections[2].rows[0].repo, "aur")
})

test("a failed document renders no sections at all", function () {
  var doc = Model.parseReport(report({ ok: false, error: "Offline.", packages: many(5) }))
  assert.deepStrictEqual(Model.sections(doc), [])
})

test("sizes read the way a person writes them", function () {
  assert.strictEqual(Model.formatBytes(0), "")
  assert.strictEqual(Model.formatBytes(512), "512 B")
  assert.strictEqual(Model.formatBytes(1536), "1.5 KiB")
  assert.strictEqual(Model.formatBytes(1073741824), "1.0 GiB")
})

console.log("")
console.log(passed + " passed" + (process.exitCode ? ", some failed" : ""))
