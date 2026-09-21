import QtQuick
import QtTest
import qs.Commons
import "../../ui" as Ui
import "../../ui/SafeReadme.js" as SafeReadme
import "../../ui/Navigation.js" as Navigation

TestCase {
  id: testCase
  name: "ReadmeDocument"
  when: windowShown
  visible: true
  width: 1200
  height: 900
  Component { id: documentComponent; Ui.ReadmeDocument {} }
  Component { id: pageComponent; Ui.PluginDetailPage {} }
  Component { id: clipboardComponent; TextEdit { width: 200; height: 100 } }
  SignalSpy { id: linkSpy; signalName: "linkRequested" }
  readonly property var originalFont: ({family:"monospace",caption:12,bodySmall:14,body:16,subtitle:18,title:22})
  function init() { failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot assign)/) }
  function cleanup() { Style.font = originalFont; linkSpy.target = null }
  function inline(text) { return [{kind:"text",text:text}] }
  function fixture() {
    return [
      {kind:"heading",level:1,inlines:inline("A beautiful README")},
      {kind:"paragraph",inlines:[{kind:"strong",children:inline("Bold")}, {kind:"text",text:" and "},
        {kind:"link",url:"https://example.org/guide",children:inline("a guide")}]},
      {kind:"list",marker:"•",depth:1,inlines:inline("A nested list with useful information that wraps on a narrow page.")},
      {kind:"quote",inlines:inline("A small note")},
      {kind:"code",language:"sh",text:"printf '<img src=\"https://tracker.invalid/pixel\">'\n" + new Array(30).join("long_code_")},
      {kind:"table",rows:[[inline("Feature"),inline("Value")],[inline("Theme"),inline(new Array(30).join("longvalue"))]]}
    ]
  }
  function walk(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) {
      var found = walk(child, predicate)
      if (found) return found
    }
    return null
  }
  function named(item, name) {
    var found = findChild(item, name) || walk(item, function(child) { return child.objectName === name })
    verify(found !== null, "Missing " + name)
    return found
  }
  function test_themed_layout_and_selectable_code_data() {
    return [{tag:"wide",width:1000}, {tag:"narrow",width:280}]
  }
  function test_themed_layout_and_selectable_code(data) {
    var doc = createTemporaryObject(documentComponent, testCase, {width:data.width,blocks:fixture()})
    verify(doc !== null)
    compare(doc.blocks.length, 6)
    compare(doc.enrichmentEnabled, true)
    compare(SafeReadme.isList(doc.blocks), true)
    compare(doc.hasBlocks, true)
    wait(0)
    verify(waitForPolish(doc))
    var heading = named(doc, "readmeText.0")
    var code = named(doc, "readmeText.4")
    var oldHeight = doc.height
    compare(heading.font.family, Style.font.family)
    verify(heading.font.pixelSize > doc.readingSize)
    compare(code.textFormat, TextEdit.PlainText)
    verify(code.text.indexOf("<img") >= 0)
    code.forceActiveFocus()
    code.selectAll()
    compare(code.selectedText, code.text)
    verify(Navigation.textEditing(code))
    keyClick(Qt.Key_Backspace)
    compare(code.selectedText, code.text)
    Style.font = {family:"serif",caption:17,bodySmall:19,body:23,subtitle:25,title:31}
    wait(0)
    verify(waitForPolish(doc))
    compare(heading.font.family, "serif")
    compare(code.font.pixelSize, doc.readingSize)
    verify(doc.height > oldHeight)
    function bounds(item) {
      if (item.visible && item.readOnly !== undefined) {
        var point = item.mapToItem(doc, 0, 0)
        verify(point.x >= 0 && point.x + item.width <= doc.width + 1, "Selectable text must stay within reading area")
        verify(item.contentWidth <= item.width + 1, "Long tokens wrap rather than overflow")
      }
      for (var child of item.children || []) bounds(child)
    }
    bounds(doc)
  }
  function test_untrusted_tokens_have_no_html_images_or_unsafe_links() {
    var html = SafeReadme.rich([{kind:"text",text:'<img src="https://tracker.invalid/pixel">'},
      {kind:"image",url:"https://tracker.invalid/image"},
      {kind:"link",url:"file:///etc/passwd",children:inline("unsafe")},
      {kind:"code",text:"<script>bad</script>"}], "#abcdef")
    verify(html.indexOf("<img") < 0)
    verify(html.indexOf("<script") < 0)
    verify(html.indexOf("<a ") < 0)
    verify(html.indexOf("&lt;img") >= 0)
    for (var bad of ["http://example.org", "javascript:bad", "file:///etc/passwd", "https://user@example.org",
      "https://example.org:99/", "https://example.org/%0aBAD", "https://example.org/%5cBAD", "https://example.org/\"onclick=bad"])
      compare(SafeReadme.safeUrl(bad), "")
  }
  function test_links_only_request_explicit_safe_activation() {
    var doc = createTemporaryObject(documentComponent, testCase, {width:600,blocks:fixture()})
    linkSpy.target = doc
    linkSpy.clear()
    wait(0)
    compare(linkSpy.count, 0)
    var prose = named(doc, "readmeText.1")
    prose.linkActivated("file:///etc/passwd")
    compare(linkSpy.count, 0)
    var position = prose.positionToRectangle(prose.getText(0, prose.length).indexOf("a guide") + 1)
    mouseMove(prose, position.x + 1, position.y + position.height / 2)
    tryCompare(prose, "hoveredLink", "https://example.org/guide")
    compare(linkSpy.count, 0, "Hover must never launch a link")
    mouseClick(prose, position.x + 1, position.y + position.height / 2)
    compare(linkSpy.count, 1)
    compare(linkSpy.signalArguments[0][0], "https://example.org/guide")
  }
  function test_default_expansion_resets_per_identity_and_fallback_states() {
    var page = createTemporaryObject(pageComponent, testCase, {width:900,height:700,
      presentation:{known:false,installed:false,widget:false,exclusive:false,canRemove:false},
      pluginRow:{id:"example.one",readmeAvailable:true,readmeLoading:true}})
    verify(page !== null)
    compare(page.documentationExpanded, true)
    var doc = named(page, "readmeDocument")
    var fallback = named(doc, "readmeFallback")
    compare(fallback.text, "Loading documentation…")
    page.documentationExpanded = false
    page.pluginRow = {id:"example.two",readmeText:"<img src=\"file:///etc/passwd\"> Plain cached text"}
    compare(page.documentationExpanded, true)
    compare(fallback.textFormat, TextEdit.PlainText)
    verify(fallback.text.indexOf("Plain cached text") >= 0)
    page.pluginRow = {id:"example.two",readmeBlocks:fixture(),readmeEnrichment:false}
    compare(doc.hasBlocks, false)
    compare(fallback.text, "README enrichment is disabled in settings.")
    page.pluginRow = {id:"example.two"}
    compare(fallback.text, "Documentation is not currently available.")
  }

  function test_focused_readme_scroll_and_native_selection_data() {
    var rows = []
    for (var size of [{tag:"wide",width:1180,height:740}, {tag:"short",width:728,height:430}])
      for (var kind of ["fallback", "paragraph", "code", "table"])
        rows.push({tag:size.tag + "-" + kind,width:size.width,height:size.height,kind:kind})
    return rows
  }
  function test_focused_readme_scroll_and_native_selection(data) {
    var lines = new Array(80).join("Readable documentation with several words.\n")
    var blocks = []
    for (var i = 0; i < 12; i++) blocks.push({kind:"paragraph",inlines:inline(lines)})
    var target = data.kind === "code" ? {kind:"code",text:lines}
      : data.kind === "table" ? {kind:"table",rows:[[inline(lines)]]}
      : {kind:"paragraph",inlines:[{kind:"link",url:"https://example.org/guide",children:inline("A guide")},
          {kind:"text",text:"\n" + lines}]}
    blocks.push(target)
    blocks.push({kind:"paragraph",inlines:inline(lines)})
    var page = createTemporaryObject(pageComponent, testCase, {width:data.width,height:data.height,
      presentation:{known:false,installed:false,widget:false,exclusive:false,canRemove:false},
      pluginRow:{id:"example.scrolling",readmeText:lines,readmeBlocks:data.kind === "fallback" ? [] : blocks}})
    verify(page !== null)
    wait(0)
    verify(waitForPolish(page))
    var doc = named(page, "readmeDocument")
    var text = data.kind === "fallback" ? named(doc, "readmeFallback")
      : data.kind === "table" ? walk(named(doc, "readmeBlock.12"), function(item) {
          return item.visible && item.readOnly === true
        }) : named(doc, "readmeText.12")
    verify(text !== null)
    verify(text.readOnly && Navigation.textEditing(text), "Exercise native TextEdit, not a passive text stub")
    text.forceActiveFocus()
    text.cursorPosition = 0
    var flick = named(page, "detailContentScroll").contentItem
    var origin = text.mapToItem(flick.contentItem, 0, 0).y
    flick.contentY = origin
    var cursor = text.cursorPosition
    var y = flick.contentY
    keyClick(Qt.Key_Down)
    verify(flick.contentY > y, "Unselected README text scrolls its enclosing page")
    var lineStep = flick.contentY - y
    verify(lineStep >= page.readingSize * 2 && lineStep <= page.readingSize * 4)
    compare(text.cursorPosition, cursor, "Scrolling leaves the invisible caret in place")
    verify(text.activeFocus)
    keyClick(Qt.Key_Up)
    fuzzyCompare(flick.contentY, y, 0.1)
    keyClick(Qt.Key_PageDown)
    fuzzyCompare(flick.contentY, y + flick.height, 0.1, "PageDown uses the containing viewport, not the tall TextEdit")
    keyClick(Qt.Key_PageUp)
    fuzzyCompare(flick.contentY, y, 0.1)
    keyClick(Qt.Key_End)
    fuzzyCompare(flick.contentY, flick.contentHeight - flick.height, 0.1)
    keyClick(Qt.Key_Down)
    fuzzyCompare(flick.contentY, flick.contentHeight - flick.height, 0.1)
    keyClick(Qt.Key_Home)
    compare(flick.contentY, 0)
    // Keep focus deep in the expanded document while reading elsewhere.
    verify(text.activeFocus)
    keyClick(Qt.Key_Right)
    compare(text.cursorPosition, cursor + 1, "Horizontal caret navigation stays native")
    keyClick(Qt.Key_Down, Qt.ShiftModifier)
    verify(text.selectedText.length > 0, "Shift+Down selects native text")
    compare(flick.contentY, 0)
    keyClick(Qt.Key_Down)
    compare(flick.contentY, 0, "An existing selection keeps native arrow behavior")
    keyClick(Qt.Key_A, Qt.ControlModifier)
    compare(text.selectedText, text.getText(0, text.length))
    keyClick(Qt.Key_C, Qt.ControlModifier)
    var clipboard = createTemporaryObject(clipboardComponent, testCase)
    clipboard.paste()
    compare(clipboard.text, text.selectedText, "Ctrl+C still copies selected README text")
    for (var key of [Qt.Key_PageUp, Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End]) {
      text.selectAll()
      keyClick(key)
      compare(flick.contentY, 0, "Selection navigation does not scroll the outer pane")
      text.deselect()
      keyClick(key, Qt.ControlModifier)
      keyClick(key, Qt.ShiftModifier)
      compare(flick.contentY, 0, "Modified editor keys never become page scrolling")
    }
  }

  function test_scrolling_focused_link_dismisses_open_help() {
    var page = createTemporaryObject(pageComponent, testCase, {width:1180,height:740,
      presentation:{known:false,installed:false,widget:false,exclusive:false,canRemove:false},
      pluginRow:{id:"example.link-scrolling",readmeBlocks:[
        {kind:"paragraph",inlines:[{kind:"link",url:"https://example.org/guide",children:inline("A guide")}]},
        {kind:"code",text:new Array(100).join("Readable documentation.\n")}]}})
    verify(page !== null)
    wait(0)
    verify(waitForPolish(page))
    var doc = named(page, "readmeDocument")
    linkSpy.target = doc
    linkSpy.clear()
    var text = named(doc, "readmeText.0")
    var tip = named(text, "readmeLinkTip")
    text.forceActiveFocus()
    // Hover hit-testing is covered on the standalone document above. Start
    // with open help here to isolate dismissal by the containing page's keys.
    tip.text = "https://example.org/guide"
    tip.open()
    tryCompare(tip, "opened", true)
    keyClick(Qt.Key_Down)
    tryCompare(tip, "visible", false)
    wait(500)
    verify(!tip.visible)
    compare(linkSpy.count, 0, "Scrolling focused link text must not activate it")
    verify(text.activeFocus)
  }
}
