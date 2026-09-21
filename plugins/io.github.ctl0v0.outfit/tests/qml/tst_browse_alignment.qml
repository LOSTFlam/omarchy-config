import QtQuick
import QtTest
import qs.Commons
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "BrowseAlignment"
  when: windowShown
  width: 1600; height: 1000
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  property var savedFont
  function init() {
    savedFont = Style.font
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot assign)/)
  }
  function cleanup() { Style.font = savedFont }
  function descendants(item, predicate) {
    var found = []
    for (var child of item.children || []) {
      if (predicate(child)) found.push(child)
      found = found.concat(descendants(child, predicate))
    }
    return found
  }
  function test_responsive_filters_toolbar_status_and_counts_data() {
    return [{tag:"compact",width:760,body:12}, {tag:"wide",width:1180,body:12},
      {tag:"large-font",width:1180,body:20}]
  }
  function test_responsive_filters_toolbar_status_and_counts(data) {
    Style.font = {family:"monospace",caption:data.body-2,bodySmall:data.body-1,body:data.body,
      heading:data.body+4,subtitle:data.body+2,title:data.body+8}
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:"list"}}))
    service.hasAnalyzed = true
    service.inventoryReady = true
    service.inventory = [{id:"example.installed",enabled:true,firstParty:false,kinds:["panel"]}]
    service.setupGroups = [{id:"desktop",label:"Desktop & Navigation",total:444},
      {id:"files",label:"Files, Sync & Backup",total:398}]
    service.setupAppliedGrouping = "category"
    service.setupSections = [{id:"desktop",label:"Desktop",total:288}]
    service.setupRows = [{id:"example.installed",name:"Installed fixture",description:"A fixture",
      kind:"panel",displayGroup:"desktop",installed:true,enabled:true,stars:12,likes:34,views:56,copies:7}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse",windowWidth:data.width,windowHeight:760}))
    wait(80)
    var search = findChild(view, "browseSearchField")
    var sort = findChild(view, "browseSortPicker")
    compare(search.height, sort.height)
    compare(sort.rowHeight, search.height)
    compare(search.y, sort.y)
    var surface = search
    while (surface.parent) surface = surface.parent
    var filter = descendants(surface, function(item) { return item.objectName === "purposeFilter.desktop" })[0]
    verify(filter !== undefined)
    compare(filter.text, "Desktop & Navigation (444)")
    verify(filter.contentItem.wrapMode !== Text.NoWrap)
    verify(filter.contentItem.paintedWidth <= filter.contentItem.width + 1)
    verify(filter.contentItem.paintedHeight <= filter.contentItem.height + 1)
    compare(filter.contentItem.horizontalAlignment, Text.AlignLeft)
    compare(descendants(surface, function(item) { return item.objectName === "browseGroupHeading" })[0].text, "DESKTOP (288)")
    var card = view.browseCards()[0]
    var badge = findChild(card, "listInstalledBadge")
    var secondary = findChild(card, "listEnabledLabel")
    var status = findChild(card, "listInstallationStatus")
    verify(badge.visible && secondary.visible)
    if (secondary.horizontalAlignment === Text.AlignRight) {
      compare(badge.x + badge.width, status.width)
      compare(secondary.x + secondary.width, status.width)
    } else compare(badge.x, secondary.x)
    verify(secondary.y >= badge.y + badge.height)
    view.close()
  }
}
