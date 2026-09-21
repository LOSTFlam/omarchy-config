import QtQuick
import QtTest
import "../../ui/Presentation.js" as Presentation

TestCase {
  name: "CompactPresentation"
  function test_list_layout_uses_real_results_width_and_preserves_preview_ratio() {
    compare(Presentation.viewModes().length, 4)
    compare(Presentation.densityName("list"), "list")
    compare(Presentation.densityProfile("list").gridGap, 4)
    var narrow = Presentation.listLayout(492)
    var medium = Presentation.listLayout(912)
    var wide = Presentation.listLayout(1200)
    verify(!narrow.sideStatus)
    verify(medium.sideStatus && wide.sideStatus)
    compare(narrow.thumbnailWidth * 9 / 16, 45)
    compare(medium.thumbnailWidth * 9 / 16, 54)
    compare(wide.thumbnailWidth * 9 / 16, 63)
    compare(narrow.descriptionLines, 3)
    compare(medium.descriptionLines, 3)
    compare(wide.descriptionLines, 2)
    compare(Presentation.listLayout(900, 960, 1500).sideStatus, false)
    verify(wide.minimumHeight < medium.minimumHeight && medium.minimumHeight < narrow.minimumHeight)
  }
  function test_list_status_distinguishes_pending_disabled_available_and_queue() {
    var pending = Presentation.listStatus(false, true, true, false, false, "bar-widget")
    compare(pending.primary, "Inventory pending")
    compare(pending.secondary, "")
    var disabled = Presentation.listStatus(true, true, false, false, true, "panel")
    compare(disabled.primary, "Installed")
    compare(disabled.secondary, "Disabled")
    compare(disabled.source, "panel")
    compare(Presentation.listStatus(true, false, false, false, false, "service").primary, "")
    compare(Presentation.listStatus(true, false, false, true, false, "service").primary, "In batch")
    compare(Presentation.listStatus(false, false, false, true, false, "service").secondary, "In batch")
  }
  function test_density_profiles_keep_descriptions_and_increase_capacity() {
    compare(Presentation.densityName("unsupported"), "comfortable")
    var comfortable = Presentation.densityProfile("comfortable")
    var compact = Presentation.densityProfile("compact")
    var dense = Presentation.densityProfile("dense")
    compare(comfortable.descriptionLines, 4)
    verify(compact.descriptionLines >= comfortable.descriptionLines)
    verify(dense.descriptionLines >= comfortable.descriptionLines)
    verify(comfortable.previewHeight > compact.previewHeight)
    verify(compact.previewHeight > dense.previewHeight && dense.previewHeight >= 96)
    compare(Presentation.cardColumns(1136, comfortable.minimumWidth, comfortable.gridGap), 3)
    compare(Presentation.cardColumns(1136, compact.minimumWidth, compact.gridGap), 4)
    compare(Presentation.cardColumns(1040, dense.minimumWidth, dense.gridGap), 4)
  }
  function test_kind_footer_preserves_all_kinds_without_source_status() {
    compare(Presentation.pluginKinds({kinds:["bar-widget", "panel", "service"],kind:"panel"}), "bar-widget · panel · service")
    compare(Presentation.pluginKinds({kind:"overlay"}), "overlay")
    compare(Presentation.pluginKinds({kinds:[]}), "Plugin")
  }
  function test_metric_layout_keeps_full_numbers_and_labels_inside_cells() {
    var tight = Presentation.metricLayout(224, 114, 102, 8)
    compare(tight.columns, 2)
    verify(tight.left >= 114 && tight.right >= 102)
    compare(tight.left + tight.right + 8, 224)
    compare(Presentation.metricLayout(210, 114, 102, 8).columns, 1)
    var wide = Presentation.metricLayout(520, 114, 102, 8)
    compare(wide.columns, 2)
    verify(wide.left >= 114 && wide.right >= 102)
    compare(wide.left, 130)
    compare(wide.right, 118)
    verify(wide.left + wide.right + 8 < 520, "Extra space does not spread columns")
    compare(4 % wide.columns, 0)
    var balanced = Presentation.metricLayout(320, 114, 102, 8)
    compare(balanced.left - 114, balanced.right - 102, "Equal bounded column padding")
  }
  function test_scroll_anchor_handles_reflow_and_content_edges() {
    compare(Presentation.anchoredScroll(400, -20, -120, 1600, 500), 300)
    compare(Presentation.anchoredScroll(400, -20, 80, 1600, 500), 500)
    compare(Presentation.anchoredScroll(0, 40, 20, 1600, 500), 0)
    compare(Presentation.anchoredScroll(400, -20, 80, 700, 500), 200)
    compare(Presentation.anchoredScroll(100, -20, 50, 300, 500), 0)
  }
  function test_natural_metrics_reduce_gaps_before_wrapping() {
    var widths = [80, 24, 100, 30]
    compare(Presentation.naturalMetricLayout(400, widths, 8, 2).columns, 4)
    compare(Presentation.naturalMetricLayout(400, widths, 8, 2).gap, 8)
    compare(Presentation.naturalMetricLayout(249, widths, 8, 2).gap, 5)
    compare(Presentation.naturalMetricLayout(240, widths, 8, 2).columns, 4)
    compare(Presentation.naturalMetricLayout(240, widths, 8, 2).gap, 2)
    compare(Presentation.naturalMetricLayout(239, widths, 8, 2).columns, 2)
    compare(Presentation.naturalMetricLayout(131, widths, 8, 2).columns, 1)
  }
  function test_grid_uses_reclaimed_sidebar_width_without_tiny_cards() {
    compare(Presentation.cardColumns(0, 290, 8), 1)
    compare(Presentation.cardColumns(580, 290, 8), 1)
    compare(Presentation.cardColumns(588, 290, 8), 2)
    compare(Presentation.cardColumns(1050, 290, 8), 3)
    compare(Presentation.cardColumns(1050 + 236, 290, 8), 4)
    compare(Presentation.cardColumns(1800, 290, 8), 6)
  }
  function test_counts_distinguish_reported_zero_and_unknown() {
    compare(Presentation.countLabel("Tailscale", 18), "Tailscale (18)")
    compare(Presentation.countLabel("Available", 0, true), "Available (0)")
    compare(Presentation.countLabel("Installed", 0, false), "Installed (—)")
    compare(Presentation.countLabel("Hardware match", null), "Hardware match (—)")
    compare(Presentation.countLabel("Source", NaN), "Source (—)")
    compare(Presentation.countLabel("Purpose", -1), "Purpose (—)")
  }
  function test_relative_times_handle_missing_and_future_timestamps() {
    var now = 1000000000
    compare(Presentation.relativeAge(0, now), "Not yet")
    compare(Presentation.relativeAge(NaN, now), "Not yet")
    compare(Presentation.relativeAge(now / 1000 - 20, now), "Just now")
    compare(Presentation.relativeAge(now / 1000 - 900, now), "15m ago")
    compare(Presentation.relativeAge(now / 1000 - 7200, now), "2h ago")
    compare(Presentation.relativeAge(now / 1000 - 172800, now), "2d ago")
    compare(Presentation.relativeAge(now / 1000 + 600, now), "Time unavailable")
  }
  function test_only_successful_manual_maintenance_gets_completion_copy() {
    compare(Presentation.completion("rescan", true, false), "")
    compare(Presentation.completion("analyze", false, false), "")
    compare(Presentation.completion("enrich", false, false), "")
    compare(Presentation.completion("rescan", false, false), "System updated")
    compare(Presentation.completion("refresh", false, false), "Catalog updated")
    compare(Presentation.completion("refresh", false, true), "")
  }
}
