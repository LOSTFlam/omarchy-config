import QtQuick
import QtQuick.Window
import QtTest
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "ReadmeWiring"
  when: windowShown
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  function init() { failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot assign)/) }
  function make(enabled) {
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeGeneration,
      preferences:{watchHardware:false,readmeEnrichment:enabled,readmeIndexing:false,marketplaceThumbnails:false,services:[]}}))
    service.inventoryReady = true
    service.setupRows = [{id:"example.reading",name:"Reading fixture",description:"Fictional documentation",
      readmeAvailable:true,installAvailable:false,kinds:["service"],kind:"Service",listingCommit:new Array(41).join("a")}]
    service.setupTotal = 1
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    verify(view !== null)
    view.open(JSON.stringify({setupStage:"browse",workspaceView:"browse"}))
    view.openSetupDetail(service.setupRows[0])
    wait(0)
    return view
  }
  function walk(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) {
      var found = walk(child, name)
      if (found) return found
    }
    return null
  }
  function test_open_fetches_default_document_and_response_is_identity_scoped_data() {
    return [{tag:"normal-response",stale:false}, {tag:"inventory-changed-response",stale:true}]
  }
  function test_open_fetches_default_document_and_response_is_identity_scoped(data) {
    var view = make(true)
    var service = view.service
    var page = findChild(view, "pluginDetailPage")
    verify(page !== null && page.visible)
    compare(page.documentationExpanded, true)
    compare(service.requestedReadmeId, "example.reading", "Opening the detail requests the README without disclosure clicks")
    compare(page.pluginRow.readmeLoading, true, "Queued README requests show the loading state too")
    var blocks = [{kind:"heading",level:1,inlines:[{kind:"text",text:"Pinned heading"}]}]
    var request = {action:"readme-plugin",pluginId:"example.reading",generation:12,
      readmeIdentity:service.requestedReadmeIdentity,
      inventoryRevision:service.inventoryRevision - (data.stale ? 1 : 0)}
    verify(service.applyResponse({ok:true,action:"readme-plugin",generation:12,readmePluginId:"example.reading",
      readmeContent:"Plain fallback",readmeBlocks:blocks,readmeMedia:[],readmeMediaIndexed:true}, request))
    compare(service.readmeBlocks, blocks)
    compare(page.pluginRow.readmeBlocks, blocks)
    wait(0)
    var text = walk(page, "readmeText.0")
    verify(text !== null)
    var scroll = findChild(page, "detailContentScroll")
    scroll.contentItem.contentY = Math.max(0, scroll.contentItem.contentHeight - scroll.height)
    text.forceActiveFocus()
    text.selectAll()
    keyClick(Qt.Key_Backspace)
    compare(view.setupDetailId, "example.reading", "README selection owns Backspace rather than navigating back")
    compare(text.selectedText, "Pinned heading")
    var other = Object.assign({}, service.setupRows[0], {id:"example.other"})
    view.openSetupDetail(other)
    compare(page.pluginRow.readmeBlocks.length, 0, "A previous listing's document must not flash in the next inspector")
    verify(service.applyResponse({ok:true,action:"readme-plugin",generation:12,
      readmePluginId:"example.reading",readmeBlocks:blocks}, request))
    compare(page.pluginRow.readmeBlocks.length, 0, "Late response remains identity scoped")
    view.close()
  }
  function test_disabled_enrichment_neither_requests_nor_displays_cached_document() {
    var view = make(false)
    var service = view.service
    compare(service.requestedReadmeId, "")
    compare(service.pendingReadmeId, "")
    service.readmePluginId = "example.reading"
    service.readmeContent = "Old cached text"
    service.readmeBlocks = [{kind:"heading",level:1,inlines:[{kind:"text",text:"Old heading"}]}]
    var page = findChild(view, "pluginDetailPage")
    compare(page.pluginRow.readmeText, "")
    compare(page.pluginRow.readmeBlocks.length, 0)
    compare(walk(page, "readmeFallback").text, "README enrichment is disabled in settings.")
    view.close()
  }
  function test_same_plugin_new_revision_does_not_reuse_or_accept_old_document() {
    var view = make(true), service = view.service
    var oldKey = service.requestedReadmeIdentity
    service.readmePluginId = "example.reading"
    service.readmeIdentity = oldKey
    service.readmeContent = "Old revision"
    service.readmeBlocks = [{kind:"paragraph",text:"Old revision"}]
    service.readmeMediaIndexed = true
    var next = Object.assign({},service.setupRows[0],{listingCommit:"b".repeat(40)})
    service.loadReadme(next)
    verify(service.requestedReadmeIdentity !== oldKey)
    compare(service.readmePluginId,"")
    compare(service.readmeBlocks.length,0)
    verify(service.applyResponse({ok:true,action:"readme-plugin",generation:99,readmePluginId:"example.reading",readmeContent:"Old revision"},
      {action:"readme-plugin",generation:99,pluginId:"example.reading",readmeIdentity:oldKey}))
    compare(service.readmeContent,"")
    view.close()
  }
}
