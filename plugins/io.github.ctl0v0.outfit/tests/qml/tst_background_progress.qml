import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "BackgroundProgress"
  when: windowShown
  Component { id: component; Plugin.BackgroundWorker { helperPath:"/fixture/helper.py" } }
  Component {
    id: reentrantComponent
    Plugin.BackgroundWorker {
      helperPath:"/fixture/helper.py"
      property int completions: 0
      onFinished: {
        completions++
        if (completions === 1) submit("second",{})
      }
    }
  }
  SignalSpy { id: finals; signalName:"finished" }
  SignalSpy { id: updates; signalName:"progress" }
  function worker() {
    var object = createTemporaryObject(component, testCase)
    finals.target = object; finals.clear()
    updates.target = object; updates.clear()
    verify(object.submit("prepare-search", {streamProgress:true}))
    return object
  }
  function line(object, values) {
    var result = {action:object.activeRequest.action, generation:object.generation}
    for (var key in values) result[key] = values[key]
    object.receiveLine(JSON.stringify(result))
  }
  function exit(object, code) {
    var process = findChild(object, "backgroundWorker")
    process.running = false
    process.exited(code || 0, 0)
  }
  function test_progress_is_correlated_monotonic_and_never_final() {
    var object = worker()
    line(object, {responseKind:"progress",final:false,sequence:1,processed:2,total:9})
    compare(updates.count, 1)
    verify(object.active)
    verify(!object.received)
    line(object, {responseKind:"progress",final:false,sequence:1})
    line(object, {responseKind:"progress",final:false,sequence:2,generation:99})
    line(object, {responseKind:"progress",final:false,sequence:2,action:"wrong"})
    line(object, {responseKind:"progress",final:false,sequence:2.5})
    compare(updates.count, 1)
    line(object, {responseKind:"progress",final:false,sequence:3})
    compare(updates.count, 2)
    compare(finals.count, 0)
    line(object, {ok:true,searchPack:{state:"ready"}})
    compare(finals.count, 0)
    exit(object)
    compare(finals.count, 1)
    verify(finals.signalArguments[0][0].ok)
  }
  function test_legacy_final_and_exit_before_stdout_are_supported() {
    var object = worker()
    exit(object)
    verify(object.active)
    line(object, {ok:true})
    compare(finals.count, 1)
    verify(finals.signalArguments[0][0].ok)
  }
  function test_legacy_eof_finish_callback_cannot_complete_the_next_request() {
    var object = createTemporaryObject(reentrantComponent,testCase)
    finals.target = object; finals.clear()
    verify(object.submit("first",{}))
    var parser = findChild(object,"backgroundParser")
    parser.read(JSON.stringify({ok:true,action:"first",generation:object.generation}))
    exit(object)
    var drain = findChild(object,"backgroundDrain")
    drain.stop(); drain.triggered()
    compare(object.completions,1)
    compare(object.activeRequest.action,"second")
    verify(object.active && !object.received)
    parser.read(JSON.stringify({ok:true,action:"second",generation:object.generation}) + "\n")
    exit(object)
    compare(object.completions,2)
    compare(finals.count,2)
    verify(finals.signalArguments[0][0].ok && finals.signalArguments[1][0].ok)
  }
  function test_progress_only_eof_is_failure() {
    var object = worker()
    line(object, {responseKind:"progress",final:false,sequence:1,total:1,processed:1})
    exit(object)
    findChild(object, "backgroundDrain").triggered()
    compare(finals.count, 1)
    verify(!finals.signalArguments[0][0].ok)
  }
  function test_cancellation_rejects_late_final_and_old_generation() {
    var object = worker()
    var process = findChild(object, "backgroundWorker")
    process.processId = 123
    object.stop("Paused", true)
    line(object, {ok:true})
    verify(object.active)
    exit(object)
    findChild(object, "backgroundDrain").triggered()
    compare(finals.count, 1)
    verify(finals.signalArguments[0][0].cancelled)
    process.processId = 0
    verify(object.submit("prepare-search", {}))
    line(object, {ok:true,generation:object.generation - 1})
    verify(!object.received)
    line(object, {ok:true})
    exit(object)
    compare(finals.count, 2)
  }
  function test_timeout_and_nonzero_exit_do_not_claim_success() {
    var object = worker()
    findChild(object, "backgroundDeadline").triggered()
    verify(!object.active)
    verify(!finals.signalArguments[0][0].ok)
    verify(object.submit("prepare-search", {}))
    line(object, {ok:true})
    exit(object, 2)
    verify(!finals.signalArguments[1][0].ok)
  }
  function test_limits_and_malformed_lines_fail_once() {
    var object = worker()
    object.receiveLine("not json")
    compare(finals.count, 1)
    verify(!finals.signalArguments[0][0].ok)
    verify(object.submit("prepare-search", {}))
    object.outputLines = object.maxOutputLines
    line(object, {ok:true})
    compare(finals.count, 2)
    verify(!finals.signalArguments[1][0].ok)
    verify(object.submit("prepare-search", {}))
    object.outputBytes = object.maxOutputBytes
    line(object, {ok:true})
    compare(finals.count, 3)
    verify(object.submit("prepare-search", {}))
    object.receiveLine("x".repeat(object.maxLineBytes + 1))
    compare(finals.count, 4)
    verify(!finals.signalArguments[3][0].ok)
  }
}
