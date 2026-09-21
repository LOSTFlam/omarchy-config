import QtQuick
import QtQuick.Window
import QtTest
import "../.." as Plugin
import "../../ui" as Ui
import "../../ui/MediaPaths.js" as Paths

TestCase {
  id: testCase
  name: "UiPerformance"
  when: windowShown
  visible: true
  width: 1180; height: 760
  Component { id: appComponent; Ui.OutfitApp {} }
  Component { id: detailComponent; Ui.PluginDetailPage {} }
  Component { id: spyComponent; SignalSpy {} }
  Component {
    id: serviceComponent
    Plugin.Service {
      property var thumbnailCalls: []
      property var remembered: []
      property var invalidations: []
      function setThumbnailRows(rows) { thumbnailCalls = thumbnailCalls.concat([rows.slice()]) }
      function rememberEditor(payload) { remembered = remembered.concat([payload]) }
      function invalidateThumbnail(id, source) { invalidations = invalidations.concat([{id:id,source:source}]) }
    }
  }
  function init() {
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot call method|Cannot assign)/)
  }
  function fixture() {
    var service = createTemporaryObject(serviceComponent,testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeGeneration,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:true,services:[]}}))
    service.inventoryReady = true
    var rows = []
    for (var i = 0; i < 40; i++) rows.push({id:"performance." + i,name:"Fictional plugin " + i,
      description:"A fictional listing for viewport demand tests.",kind:"panel",likes:i,stars:i,views:i,copies:i,
      previewThumbnail:"https://example.invalid/preview-" + i + ".png",installAvailable:true})
    service.setupRows = rows
    var app = createTemporaryObject(appComponent,testCase,{service:service})
    app.open(JSON.stringify({setupStage:"browse",windowWidth:1180,windowHeight:760}))
    settleBrowseDemand(app)
    return app
  }
  function descendants(item, predicate) {
    var result = []
    for (var child of item.children || []) {
      if (predicate(child)) result.push(child)
      result = result.concat(descendants(child,predicate))
    }
    return result
  }
  function demand(service) { return service.thumbnailCalls[service.thumbnailCalls.length - 1] || [] }
  function ids(rows) { return rows.map(function(row) { return row.id }).join(",") }
  function expectedBrowseDemand(app) {
    var viewport = findChild(app,"browseResultsScroll")
    return app.browseCards().filter(function(card) {
      var point = card.mapToItem(viewport,0,0)
      return point.y + card.height > -100 && point.y < viewport.height + 100
    }).map(function(card) { return card.pluginRow })
  }
  function settleBrowseDemand(app) {
    var viewport = findChild(app,"browseResultsScroll")
    var window = viewport.Window.window
    var timer = findChild(app,"thumbnailDemandTimer")
    // Flush deferred anchor/focus work, then wait for actual positioner polish
    // and the one-shot demand update, rather than assuming a frame-time budget.
    wait(0)
    verify(waitForPolish(window),"Browse layout polishes")
    tryVerify(function() {
      return !isPolishScheduled(window) && !timer.running
        && ids(demand(app.service)) === ids(expectedBrowseDemand(app))
    },5000,"Settled thumbnail demand matches the current viewport")
  }
  function test_thumbnail_demand_is_event_driven_and_semantically_deduplicated() {
    var app = fixture(), service = app.service
    tryCompare(service,"queryLaunching",false)
    settleBrowseDemand(app)
    var timer = findChild(app,"thumbnailDemandTimer")
    var spy = createTemporaryObject(spyComponent,testCase,{target:timer,signalName:"triggered"})
    verify(spy.valid)
    verify(demand(service).length > 0 && demand(service).length < service.setupRows.length)
    var first = ids(demand(service)), count = service.thumbnailCalls.length
    wait(800)
    compare(spy.count,0,"No stationary thumbnail polling")
    compare(service.thumbnailCalls.length,count)
    for (var i = 0; i < 100; i++) app.scheduleThumbnailDemand()
    settleBrowseDemand(app)
    compare(spy.count,1,"Layout notifications share a single timer")
    compare(service.thumbnailCalls.length,count,"Unchanged demand does not call Service")
    var scroll = findChild(app,"browseResultsScroll")
    scroll.contentItem.contentY = 1700
    settleBrowseDemand(app)
    verify(ids(demand(service)) !== first)
    var before = app.viewportAnchor()
    app.chooseDensity("list")
    settleBrowseDemand(app)
    verify(demand(service).length > 0)
    compare(app.viewportAnchor().id,before.id,"Density reflow keeps the viewport anchor")
    compare(ids(demand(service)),ids(expectedBrowseDemand(app)))
    var calls = service.thumbnailCalls.length
    service.setupRows = service.setupRows.map(function(row) { return Object.assign({},row) })
    settleBrowseDemand(app)
    compare(service.thumbnailCalls.length,calls,"Equivalent model replacement is deduplicated")
    app.setFiltersExpanded(false)
    settleBrowseDemand(app)
    compare(ids(demand(service)),ids(expectedBrowseDemand(app)))
    scroll.Window.window.width = 760
    scroll.Window.window.height = 540
    settleBrowseDemand(app)
    compare(ids(demand(service)),ids(expectedBrowseDemand(app)),"Resize refreshes the visible demand")
    var card = app.browseCards()[20]
    app.openSetupDetail(card.pluginRow,card)
    tryCompare(timer,"running",false)
    tryVerify(function() { return ids(demand(service)) === card.pluginRow.id })
    app.closeSetupDetail()
    settleBrowseDemand(app)
    verify(demand(service).length > 1,"Back restores viewport demand")
    compare(ids(demand(service)),ids(expectedBrowseDemand(app)))
    service.preferences = Object.assign({},service.preferences,{marketplaceThumbnails:false})
    compare(demand(service).length,0)
    service.preferences = Object.assign({},service.preferences,{marketplaceThumbnails:true})
    tryVerify(function() { return demand(service).length > 0 })
    app.close()
    compare(demand(service).length,0)
    spy.clear()
    wait(400)
    compare(spy.count,0)
  }
  function test_thumbnail_demand_tracks_positioning_without_outer_size_changes() {
    var app = fixture(), service = app.service
    // The inert worker reports its launch timeout asynchronously. Let that real
    // status-banner resize settle before isolating a card-only geometry change.
    tryCompare(service,"queryLaunching",false)
    settleBrowseDemand(app)
    var viewport = findChild(app,"browseResultsScroll")
    var cards = app.browseCards()
    compare(cards[0].y,cards[1].y,"The two cards share a grid row")
    var fullHeight = cards[0].height
    // A shorter card's tail is outside the prefetch margin, while its taller
    // neighbour still determines the row height and is demanded.
    cards[0].height = 1
    viewport.contentItem.contentY = 150
    settleBrowseDemand(app)
    verify(!demand(service).some(function(row) { return row.id === cards[0].pluginRow.id }))
    verify(demand(service).some(function(row) { return row.id === cards[1].pluginRow.id }))
    var before = ids(demand(service))
    var contentHeight = viewport.contentItem.contentHeight
    var contentY = viewport.contentItem.contentY
    var viewportHeight = viewport.height
    var heightSpy = createTemporaryObject(spyComponent,testCase,
      {target:viewport.contentItem,signalName:"contentHeightChanged"})
    // Late nested-card reflow grows that card into demand without changing
    // the grid row, total content height, viewport size, or scroll position.
    cards[0].height = fullHeight
    verify(waitForPolish(viewport.Window.window))
    compare(heightSpy.count,0,"No intermediate outer-size notification masks the missing event")
    compare(viewport.contentItem.contentHeight,contentHeight)
    compare(viewport.contentItem.contentY,contentY)
    compare(viewport.height,viewportHeight)
    verify(ids(expectedBrowseDemand(app)) !== before,"The demand boundary moved")
    settleBrowseDemand(app)
    compare(heightSpy.count,0)
    compare(viewport.height,viewportHeight)
    verify(demand(service).some(function(row) { return row.id === cards[0].pluginRow.id }))
    var timer = findChild(app,"thumbnailDemandTimer")
    var spy = createTemporaryObject(spyComponent,testCase,{target:timer,signalName:"triggered"})
    var calls = service.thumbnailCalls.length
    wait(400)
    compare(spy.count,0,"Completed positioning does not start a permanent polling loop")
    compare(service.thumbnailCalls.length,calls)
    compare(viewport.contentItem.contentY,contentY,"Demand refresh never resets scroll")
    app.close()
  }
  function test_panel_remember_bursts_coalesce_and_close_flushes_drafts() {
    var app = fixture(), service = app.service
    var timer = findChild(app,"panelRememberTimer")
    service.remembered = []
    for (var i = 0; i < 100; i++) app.rememberPanel()
    compare(service.remembered.length,0)
    wait(160)
    compare(service.remembered.length,1)
    app.settingsOpen = true
    app.draftReadmes = true
    app.settingsTouched = true
    app.rememberPanel()
    var count = service.remembered.length
    app.close()
    compare(service.remembered.length,count + 1)
    var saved = service.remembered[service.remembered.length - 1]
    verify(saved.settingsOpen && saved.settingsTouched && saved.draft.readmeEnrichment)
    compare(timer.running,false)
    wait(300)
    compare(service.remembered.length,count + 1)
  }
  function test_only_current_card_layout_is_constructed() {
    var app = fixture()
    for (var density of ["comfortable","list","dense"]) {
      app.chooseDensity(density)
      wait(120)
      var card = app.browseCards()[0]
      var layouts = descendants(card,function(item) { return item.objectName === "gridCardCopy" || item.objectName === "listCardCopy" })
      compare(layouts.length,1,"Only one card layout exists, including hidden children")
      compare(layouts[0].objectName,density === "list" ? "listCardCopy" : "gridCardCopy")
      var counts = descendants(card,function(item) { return ["likes","stars","views","copies"].indexOf(item.metric) >= 0 })
      compare(counts.length,4,"No duplicate hidden metric helpers")
    }
    app.close()
  }
  function test_cached_image_errors_invalidate_only_the_current_uri() {
    var app = fixture(), service = app.service
    var row = service.setupRows[0]
    var uri = Paths.cachePrefix(service.cacheRoot) + "thumb-" + "a".repeat(32) + "-" + "b".repeat(16) + ".png"
    var cache = ({})
    cache[row.id] = {url:row.previewThumbnail,localSource:uri,state:"ready"}
    var loaders = descendants(service,function(item) { return item.images !== undefined && typeof item.rowKey === "function" })
    compare(loaders.length,1)
    ignoreWarning(/.*QQuickImage: Cannot open: file:.*thumb-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb\.png/)
    loaders[0].images = cache
    tryVerify(function() { return service.invalidations.length > 0 })
    compare(service.invalidations[0].id,row.id)
    compare(service.invalidations[0].source,uri)
    var count = service.invalidations.length
    app.invalidateThumbnail(row.id,uri + ".old")
    app.invalidateThumbnail("other-id",uri)
    compare(service.invalidations.length,count)
    service.preferences = Object.assign({},service.preferences,{marketplaceThumbnails:false})
    var images = descendants(app.browseCards()[0],function(item) { return item.sourceSize !== undefined && item.status !== undefined })
    compare(images.length,1)
    compare(String(images[0].source),"")
    app.close()
  }
  function test_sleep_releases_browse_delegates_without_mutating_drafts() {
    var app = fixture(), service = app.service
    if (typeof service.sleeping !== "boolean") { app.close(); skip("Parent Service.sleeping contract is not integrated yet"); return }
    app.settingsTouched = true
    app.draftReadmes = true
    app.serviceDraft = ["fictional-interest"]
    service.sleeping = true
    wait(0)
    compare(app.browseCards().length,0)
    verify(app.settingsTouched && app.draftReadmes)
    compare(app.serviceDraft,["fictional-interest"])
    compare(demand(service).length,0)
    service.sleeping = false
    wait(150)
    compare(app.browseCards().length,40)
    app.close()
  }
  function test_generic_gallery_fullsize_is_lazy_async_and_bounded() {
    var source = Qt.resolvedUrl("../../demo/assets/detail-dockside-overview.svg")
    // Existing fixture asset, also used by the gallery tests.
    var page = createTemporaryObject(detailComponent,testCase,{width:1100,height:700,
      pluginRow:{id:"fictional.gallery"},mediaItems:[{source:source,title:"Fixture"}],
      presentation:{known:true,installed:false,exclusive:false,selected:false,failed:false,widget:false}})
    verify(page !== null)
    var full = findChild(page,"detailFullSizeImage")
    compare(String(full.source),"")
    verify(full.asynchronous)
    verify(full.sourceSize.width <= 4096 && full.sourceSize.height <= 4096)
    var preview = findChild(page,"detailPreview")
    tryCompare(preview,"status",Image.Ready)
    preview.clicked()
    tryCompare(full,"status",Image.Ready)
    verify(String(full.source).length > 0)
    findChild(page,"detailFullSizePopup").close()
    compare(String(full.source),"")
    page.active = false
    compare(String(preview.source),"")
  }
  function test_suspended_detail_releases_documents_and_restores_reading_position() {
    var blocks = []
    for (var i = 0; i < 100; i++) blocks.push({kind:"paragraph",text:"Fictional documentation paragraph " + i})
    var page = createTemporaryObject(detailComponent,testCase,{width:1100,height:700,
      pluginRow:{id:"fictional.docs",readmeBlocks:blocks,readmeText:"Fallback documentation"},
      presentation:{known:true,installed:false,exclusive:false,selected:false,failed:false,widget:false}})
    wait(0)
    var document = findChild(page,"readmeDocument")
    compare(document.blocks.length,100)
    page.restorePosition(1300,"close")
    var position = page.scrollPosition()
    verify(position > 1000)
    page.active = false
    wait(0)
    compare(document.blocks.length,0)
    compare(document.plainText,"")
    compare(page.scrollPosition(),position)
    page.active = true
    wait(40)
    compare(document.blocks.length,100)
    compare(page.scrollPosition(),position)
    page.active = false
    page.pluginRow = {id:"fictional.docs",readmeLoading:true,readmeBlocks:[]}
    page.active = true
    wait(40)
    compare(page.scrollPosition(),position,"Pending README loading retains the saved reading position")
    page.pluginRow = {id:"fictional.docs",readmeLoading:false,readmeBlocks:blocks}
    wait(40)
    compare(page.scrollPosition(),position)
    compare(findChild(page,"detailContentScroll").contentItem.contentY,position)
  }
  function test_native_fullsize_image_is_lazy_async_and_bounded() {
    var app = fixture()
    app.openSetupDetail(app.service.setupRows[0],null)
    wait(0)
    var image = findChild(app,"nativeFullSizeImage")
    verify(image !== null)
    verify(image.asynchronous)
    compare(String(image.source),"")
    verify(image.sourceSize.width > 0 && image.sourceSize.height > 0)
    verify(image.sourceSize.width <= 4096 && image.sourceSize.height <= 4096)
    app.close()
    wait(0)
    compare(findChild(app,"nativeFullSizeImage"),null,"Closing releases the native media subtree")
  }
}
