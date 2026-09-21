import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "ThumbnailLifecycle"
  when: windowShown
  Component { id: loaderComponent; Plugin.ThumbnailLoader {} }

  function row(id) {
    return { id:id, previewThumbnail:"https://plugins.omarchy.org/assets/img/plugins/" + id + ".webp" }
  }
  function fallbackRow() {
    return {id:"example.fallback", repo:"https://github.com/example/plugin",
      listingCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", previewThumbnail:"", previewImage:""}
  }
  function loader() {
    return createTemporaryObject(loaderComponent, testCase, {
      helperPath:"/fictional/helper.py", revision:"one", rows:[row("one")]
    })
  }
  function worker(object) { return findChild(object, "thumbnailWorker") }
  function timer(object, name) { return findChild(object, "thumbnail" + name) }
  function fire(object, name) {
    var clock = timer(object, name)
    clock.stop()
    clock.triggered()
  }
  function start(object, pid) {
    object.startNext()
    verify(object.active)
    if (pid) {
      worker(object).processId = pid
      worker(object).started()
    }
  }
  function exit(object, code) {
    worker(object).running = false
    worker(object).processId = 0
    worker(object).exited(code || 0, 0)
  }
  function result(object, values) {
    var images = {}
    for (var i = 0; i < object.activeRows.length; i++) {
      var active = object.activeRows[i]
      images[active.id] = {url:active.url, localSource:"file:///fictional/" + active.id + ".webp"}
      if (!active.url) images[active.id] = Object.assign(images[active.id], {
        source:"readme", state:"ready", repo:active.repo, listingCommit:active.listingCommit})
      if (values) images[active.id] = Object.assign(images[active.id], values)
    }
    return {ok:true, action:"thumbnails", generation:object.activeGeneration, thumbnails:images}
  }
  function frame(object, data) {
    findChild(object, "thumbnailParser").read((typeof data === "string" ? data : JSON.stringify(data)) + "\n")
  }
  // Preserve the original helper's public signature and both stream/exit orders.
  function complete(object, order, values) {
    var data = result(object, values)
    if (order === "exit-first") exit(object)
    frame(object, data)
    if (order !== "exit-first") exit(object)
  }
  function makeDue(object) {
    var due = {}
    Object.keys(object.attempts).forEach(function(id) { due[id] = 0 })
    object.attempts = due
  }

  function test_success_and_bounded_batch() {
    var object = loader()
    var rows = []
    for (var i = 0; i < 30; i++) rows.push(row("plugin" + i))
    object.rows = rows
    start(object, 123)
    compare(object.activeRows.length, 12)
    var input = JSON.parse(worker(object).written)
    compare(input.action, "thumbnails")
    compare(input.generation, object.activeGeneration)
    compare(input.pluginIds.length, 12)
    complete(object, "exit-first")
    compare(Object.keys(object.images).length, 12)
    start(object)
    compare(object.activeRows[0].id, "plugin12")
  }
  function test_overlapping_viewport_preserves_batch_and_accepts_only_relevant_rows() {
    var object = loader()
    object.rows = [row("a"), row("b")]
    start(object, 123)
    var generation = object.activeGeneration
    object.rows = [row("b"), row("c")]
    verify(!object.cancelled)
    verify(worker(object).running)
    compare(object.activeGeneration, generation)
    compare(object.generation, generation)
    complete(object, "stream-first")
    verify(!object.images.a)
    verify(Boolean(object.images.b.localSource))
    start(object)
    compare(object.activeRows.length, 1)
    compare(object.activeRows[0].id, "c")
    verify(object.activeGeneration > generation)
  }
  function test_reorder_does_not_relaunch_and_preserves_cache() {
    var object = loader()
    object.rows = [row("a"), row("b")]
    start(object, 123)
    var generation = object.generation
    object.rows = [row("b"), row("a")]
    verify(!object.cancelled)
    compare(object.generation, generation)
    complete(object, "exit-first")
    object.rows = [row("a"), row("b")]
    object.startNext()
    verify(!object.active)
    compare(Object.keys(object.images).length, 2)
    verify(!timer(object, "Schedule").running)
    object.rows = [row("b")]
    object.rows = [row("a"), row("b")]
    verify(!timer(object, "Schedule").running)
  }
  function test_switch_rejects_old_response_and_starts_latest() {
    var object = loader()
    start(object, 123)
    object.rows = [row("two")]
    object.rows = [row("three")]
    verify(object.cancelled)
    verify(object.active)
    verify(!worker(object).running)
    complete(object, "stream-first")
    compare(Object.keys(object.images).length, 0)
    start(object)
    compare(object.activeRows[0].id, "three")
    complete(object, "exit-first")
    verify(Boolean(object.images.three))
    verify(!object.images.one)
  }
  function test_disable_before_start_prevents_input_and_restarts_on_enable() {
    var object = loader()
    start(object)
    object.enabled = false
    worker(object).processId = 123
    worker(object).started()
    compare(worker(object).written, "")
    complete(object, "exit-first")
    compare(Object.keys(object.images).length, 0)
    verify(!object.active)
    verify(!timer(object, "Schedule").running)
    object.enabled = true
    start(object)
  }
  function test_revision_change_rejects_old_image() {
    var object = loader()
    start(object, 123)
    frame(object, result(object))
    // A parsed result must still pass hard identity and exit checks at commit.
    compare(Object.keys(object.images).length, 0)
    object.revision = "two"
    exit(object)
    compare(Object.keys(object.images).length, 0)
    start(object)
    complete(object, "stream-first")
    compare(object.images.one.revision, "two")
  }
  function test_changed_source_does_not_accept_old_row_while_overlap_survives() {
    var object = loader()
    object.rows = [row("a"), row("b")]
    start(object)
    var changed = Object.assign(row("a"), {previewThumbnail:"https://example.test/repaired.webp"})
    object.rows = [changed, row("b")]
    verify(!object.cancelled)
    complete(object, "stream-first")
    verify(!object.images.a)
    verify(Boolean(object.images.b))
    start(object)
    compare(object.activeRows[0].url, changed.previewThumbnail)
    complete(object, "stream-first")
    object.rows = [row("a"), row("b")]
    verify(!object.images.a)
    verify(Boolean(object.images.b))
  }
  function test_failed_result_backs_off_without_blocking_new_rows() {
    var object = loader()
    start(object, 123)
    frame(object, "invalid output")
    verify(object.active)
    exit(object, 1)
    verify(!object.active)
    verify(object.attempts.one > Date.now() + 4000)
    object.startNext()
    verify(!object.active)
    object.rows = [row("two")]
    start(object)
    compare(object.activeRows[0].id, "two")
  }
  function test_missing_marketplace_url_loads_readme_and_disabling_removes_it() {
    var object = loader()
    object.rows = [fallbackRow()]
    object.startNext()
    verify(!object.active)
    verify(!timer(object, "Schedule").running)
    object.readmeFallbackEnabled = true
    start(object)
    compare(object.activeRows[0].url, "")
    complete(object, "exit-first")
    compare(object.images["example.fallback"].source, "readme")
    verify(Boolean(object.images["example.fallback"].localSource))
    verify(!timer(object, "Schedule").running)
    object.readmeFallbackEnabled = false
    compare(Object.keys(object.images).length, 0)
    verify(!timer(object, "Schedule").running)
  }
  function test_policy_change_rejects_inflight_fallback() {
    var object = loader()
    object.rows = [fallbackRow()]
    object.readmeFallbackEnabled = true
    start(object, 123)
    object.readmeFallbackEnabled = false
    complete(object, "stream-first")
    compare(Object.keys(object.images).length, 0)
    verify(!timer(object, "Schedule").running)
  }
  function test_fallback_response_is_bound_to_repository_and_listing_revision_data() {
    return [
      {tag:"wrong-commit", values:{listingCommit:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},
      {tag:"wrong-repo", values:{repo:"https://github.com/other/plugin"}}
    ]
  }
  function test_fallback_response_is_bound_to_repository_and_listing_revision(data) {
    var object = loader()
    object.rows = [fallbackRow()]
    object.readmeFallbackEnabled = true
    start(object)
    complete(object, "stream-first", data.values)
    compare(object.images["example.fallback"].localSource, "")
    compare(object.images["example.fallback"].state, "failed")
    var oldKey = object.images["example.fallback"].cacheKey
    object.rows = [Object.assign(fallbackRow(), {listingCommit:"cccccccccccccccccccccccccccccccccccccccc"})]
    verify(!object.images["example.fallback"])
    start(object)
    verify(object.activeRows[0].cacheKey !== oldKey)
  }
  function test_budget_deferred_rows_retry_without_the_failure_delay() {
    var object = loader()
    start(object)
    complete(object, "stream-first", {localSource:"", state:"deferred"})
    var delay = object.attempts.one - Date.now()
    verify(delay > 800 && delay <= 1000)
    verify(timer(object, "Schedule").interval > 800)
    object.startNext()
    verify(!object.active)
    for (var i = 0; i < 10; i++) {
      makeDue(object)
      start(object)
      complete(object, "stream-first", {localSource:"", state:"deferred"})
      var nextDelay = object.attempts.one - Date.now()
      verify(nextDelay >= delay - 100 && nextDelay <= 30000)
      delay = nextDelay
    }
    verify(delay > 29000)
  }
  function test_row_thirteen_precedes_deferred_candidates_even_when_all_due() {
    var object = loader()
    var rows = []
    for (var i = 0; i < 13; i++) rows.push(row("plugin" + i))
    object.rows = rows
    start(object)
    complete(object, "stream-first", {localSource:"", state:"deferred"})
    verify(object.attempts.plugin0 > Date.now())
    makeDue(object)
    start(object)
    compare(object.activeRows[0].id, "plugin12")
    compare(object.activeRows.length, 12)
    complete(object, "stream-first")
    verify(Boolean(object.images.plugin12.localSource))
    start(object)
    compare(object.activeRows[0].id, "plugin11")
  }
  function test_failure_backoff_is_bounded() {
    var object = loader()
    var last = 0
    for (var i = 0; i < 12; i++) {
      makeDue(object)
      start(object)
      complete(object, "stream-first", {localSource:"", state:"failed"})
      var delay = object.attempts.one - Date.now()
      verify(delay >= last - 100 && delay <= 60000)
      last = delay
    }
    verify(last > 59000)
  }
  function test_recovered_fallback_retries_marketplace_and_keeps_image_during_failure() {
    var object = loader()
    object.readmeFallbackEnabled = true
    object.rows = [Object.assign(fallbackRow(), {previewThumbnail:row("one").previewThumbnail})]
    start(object)
    complete(object, "stream-first", {source:"readme", state:"ready", repo:fallbackRow().repo,
      listingCommit:fallbackRow().listingCommit})
    var source = object.images["example.fallback"].localSource
    verify(Boolean(source))
    verify(object.attempts["example.fallback"] > Date.now())
    verify(timer(object, "Schedule").running)
    makeDue(object)
    start(object)
    complete(object, "stream-first", {localSource:"", state:"failed"})
    compare(object.images["example.fallback"].localSource, source)
    makeDue(object)
    start(object)
    complete(object, "stream-first", {source:"marketplace", state:"ready", localSource:"file:///fictional/repaired.webp"})
    compare(object.images["example.fallback"].source, "marketplace")
    verify(!object.attempts["example.fallback"])
    verify(!timer(object, "Schedule").running)
  }
  function test_missing_launch_finishes_once_and_backs_off() {
    var object = loader()
    start(object)
    fire(object, "LaunchDeadline")
    verify(!object.active)
    verify(!worker(object).running)
    verify(object.attempts.one > Date.now())
    var due = object.attempts.one
    object.finish()
    exit(object)
    fire(object, "LaunchDeadline")
    compare(object.attempts.one, due)
    object.startNext()
    verify(!object.active)
  }
  function test_timeout_escalates_by_pid_and_waits_for_exit() {
    var object = loader()
    start(object, 123)
    fire(object, "Deadline")
    verify(!worker(object).running)
    verify(object.active)
    verify(timer(object, "KillDeadline").running)
    var generation = object.activeGeneration
    fire(object, "KillDeadline")
    compare(worker(object).lastSignal, 9)
    object.startNext()
    compare(object.activeGeneration, generation)
    verify(object.active)
    frame(object, result(object))
    compare(Object.keys(object.images).length, 0)
    exit(object, 9)
    verify(!object.active)
    verify(object.attempts.one > Date.now())
  }
  function test_launch_watchdog_with_live_pid_cannot_free_slot() {
    var object = loader()
    start(object)
    worker(object).processId = 123
    fire(object, "LaunchDeadline")
    verify(object.active)
    fire(object, "KillDeadline")
    compare(worker(object).lastSignal, 9)
    verify(object.active)
    worker(object).processId = 0
    fire(object, "KillDeadline")
    verify(!object.active)
    verify(object.attempts.one > Date.now())
  }
  function test_cancelled_pending_launch_waits_and_late_start_gets_no_input() {
    var object = loader()
    start(object)
    object.rows = [row("two")]
    var generation = object.activeGeneration
    object.startNext()
    compare(object.activeGeneration, generation)
    verify(object.active)
    worker(object).processId = 123
    worker(object).started()
    compare(worker(object).written, "")
    fire(object, "KillDeadline")
    compare(worker(object).lastSignal, 9)
    exit(object)
    start(object)
    compare(object.activeRows[0].id, "two")
  }
  function test_exit_without_stdout_and_nonzero_exit_are_failures() {
    var object = loader()
    start(object, 123)
    exit(object)
    verify(object.active)
    fire(object, "DrainDeadline")
    verify(!object.active)
    compare(object.images.one.state, "failed")
    verify(object.attempts.one > Date.now())
    makeDue(object)
    start(object, 124)
    frame(object, result(object))
    exit(object, 1)
    compare(object.images.one.localSource, "")
    compare(object.images.one.state, "failed")
  }
  function test_wrong_generation_action_progress_and_duplicate_frames() {
    var object = loader()
    start(object)
    var data = result(object)
    frame(object, Object.assign({}, data, {generation:data.generation - 1}))
    frame(object, Object.assign({}, data, {generation:String(data.generation)}))
    frame(object, Object.assign({}, data, {action:"other"}))
    frame(object, Object.assign({}, data, {responseKind:"progress", final:false}))
    verify(!object.received)
    frame(object, data)
    verify(object.received)
    frame(object, result(object, {localSource:"file:///fictional/duplicate.webp"}))
    exit(object)
    compare(object.images.one.localSource, "file:///fictional/one.webp")
    var due = object.attempts.one
    frame(object, "invalid late frame")
    exit(object, 1)
    object.finish()
    compare(object.attempts.one, due)
    compare(object.images.one.localSource, "file:///fictional/one.webp")
  }
  function test_output_limits_data() {
    return [{tag:"line"}, {tag:"utf8"}, {tag:"total"}, {tag:"lines"}, {tag:"malformed"}]
  }
  function test_output_limits(data) {
    var object = loader()
    start(object, 123)
    if (data.tag === "line") frame(object, "x".repeat(object.maxLineBytes + 1))
    if (data.tag === "utf8") frame(object, "雪".repeat(Math.floor(object.maxLineBytes / 3) + 1))
    if (data.tag === "total") { object.outputBytes = object.maxOutputBytes; frame(object, " ") }
    if (data.tag === "lines") { object.outputLines = object.maxOutputLines; frame(object, " ") }
    if (data.tag === "malformed") frame(object, "not-json")
    verify(Boolean(object.failure))
    verify(object.active)
    verify(!worker(object).running)
    exit(object)
    verify(!object.active)
    verify(object.attempts.one > Date.now())
  }
  function test_ready_cache_has_no_timer_and_empty_or_disabled_cancels_retry() {
    var object = loader()
    start(object)
    complete(object, "stream-first")
    verify(!timer(object, "Schedule").running)
    object.rows = [row("two")]
    start(object)
    complete(object, "stream-first", {localSource:"", state:"deferred"})
    verify(timer(object, "Schedule").running)
    object.rows = []
    verify(!timer(object, "Schedule").running)
    object.rows = [row("two")]
    verify(timer(object, "Schedule").running)
    object.enabled = false
    verify(!timer(object, "Schedule").running)
    compare(Object.keys(object.images).length, 0)
  }
  function test_next_due_timer_launches_once_then_sleeps() {
    var object = loader()
    tryCompare(object, "active", true, 1000)
    complete(object, "stream-first", {localSource:"", state:"deferred"})
    wait(250)
    verify(!object.active, "Deferred work must not relaunch on the old 180ms cadence")
    tryCompare(object, "active", true, 1500)
    complete(object, "stream-first")
    verify(!timer(object, "Schedule").running)
    wait(220)
    verify(!object.active)
  }
  function test_clear_closed_cancels_work_and_all_scheduling() {
    var object = loader()
    start(object)
    complete(object, "stream-first")
    object.rows = [row("two")]
    start(object, 123)
    object.enabled = false
    object.clear()
    verify(object.cancelled)
    compare(Object.keys(object.images).length, 0)
    compare(Object.keys(object.attempts).length, 0)
    compare(Object.keys(object.retryState).length, 0)
    complete(object, "stream-first")
    verify(!object.active)
    ;["Schedule", "LaunchDeadline", "Deadline", "KillDeadline", "DrainDeadline"].forEach(function(name) {
      verify(!timer(object, name).running)
    })
    object.enabled = true
    start(object)
    compare(object.activeRows[0].id, "two")
  }
  function test_clear_while_enabled_stays_asleep_until_new_demand() {
    var object = loader()
    start(object, 123)
    object.clear()
    complete(object, "stream-first")
    object.startNext()
    verify(!object.active)
    verify(!timer(object, "Schedule").running)
    compare(Object.keys(object.images).length, 0)
    object.rows = [row("two")]
    start(object)
  }
  function test_empty_demand_stops_active_process() {
    var object = loader()
    start(object, 123)
    object.rows = []
    verify(object.cancelled)
    verify(!timer(object, "Schedule").running)
    complete(object, "stream-first")
    verify(!object.active)
    verify(!timer(object, "Schedule").running)
    compare(Object.keys(object.images).length, 0)
  }
  function test_image_error_is_uri_conditional_and_does_not_loop() {
    var object = loader()
    start(object)
    complete(object, "stream-first")
    var source = object.images.one.localSource
    verify(!object.invalidateImage("one", "file:///fictional/stale.webp"))
    compare(object.images.one.localSource, source)
    verify(object.invalidateImage("one", source))
    compare(object.images.one.localSource, "")
    verify(!object.invalidateImage("one", source))
    object.startNext()
    verify(!object.active)
    verify(!timer(object, "Schedule").running)
    object.rows = [row("two"), row("one")]
    start(object)
    compare(object.activeRows.length, 1)
    compare(object.activeRows[0].id, "two")
    complete(object, "stream-first")
    object.revision = "two"
    start(object)
    compare(object.activeRows.length, 2)
  }
  function test_image_error_during_overlapping_batch_cannot_restore_broken_uri() {
    var object = loader()
    var fallback = Object.assign(fallbackRow(), {previewThumbnail:row("one").previewThumbnail})
    object.readmeFallbackEnabled = true
    object.rows = [fallback]
    start(object)
    var values = {source:"readme", state:"ready", repo:fallback.repo, listingCommit:fallback.listingCommit}
    complete(object, "stream-first", values)
    var source = object.images[fallback.id].localSource
    object.rows = [fallback, row("two")]
    makeDue(object)
    start(object, 123)
    var data = result(object)
    data.thumbnails[fallback.id] = Object.assign(data.thumbnails[fallback.id], values)
    verify(object.invalidateImage(fallback.id, source))
    verify(!object.cancelled, "The other row is still useful")
    frame(object, data)
    exit(object)
    compare(object.images[fallback.id].localSource, "")
    compare(object.images[fallback.id].state, "broken")
    verify(Boolean(object.images.two.localSource))
    verify(!timer(object, "Schedule").running)
  }
  function test_maps_remain_strictly_bounded() {
    var object = loader()
    for (var batch = 0; batch < 18; batch++) {
      var rows = []
      for (var i = 0; i < 12; i++) rows.push(row("plugin" + (batch * 12 + i)))
      object.rows = rows
      start(object)
      complete(object, "stream-first", {localSource:"", state:"deferred"})
      verify(Object.keys(object.images).length <= 128)
      verify(Object.keys(object.attempts).length <= 128)
      verify(Object.keys(object.retryState).length <= 128)
    }
    compare(Object.keys(object.images).length, 128)
    compare(Object.keys(object.attempts).length, 128)
    compare(Object.keys(object.retryState).length, 128)
  }
}
