import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "BoundedJson"
  when: windowShown
  Component { id: component; Plugin.BoundedJsonParser {} }
  Component { id: spyComponent; SignalSpy {} }
  function test_chunks_unicode_escape_and_legacy_eof() {
    var parser = createTemporaryObject(component,testCase)
    var frames = createTemporaryObject(spyComponent,testCase,{target:parser,signalName:"frame"})
    parser.push('{"name":"\\u26')
    compare(frames.count,0)
    parser.push('03"}\n{"next":')
    compare(frames.count,1)
    compare(JSON.parse(frames.signalArguments[0][0]).name,"☃")
    parser.push('true}')
    parser.flush()
    compare(frames.count,2)
    verify(JSON.parse(frames.signalArguments[1][0]).next)
    compare(parser.pending,"")
  }
  function test_unterminated_stream_is_bounded_and_reset_recovers() {
    var parser = createTemporaryObject(component,testCase,{maxFrameBytes:16,maxStreamBytes:32,maxFrames:2})
    var errors = createTemporaryObject(spyComponent,testCase,{target:parser,signalName:"failed"})
    parser.push("x".repeat(12))
    parser.push("x".repeat(12))
    verify(parser.rejected)
    compare(parser.pending,"")
    parser.push("x".repeat(100))
    compare(errors.count,1)
    parser.reset()
    parser.push("{}\n{}\n{}\n")
    verify(parser.rejected)
    compare(errors.count,2)
    parser.reset()
    parser.push("☃")
    verify(parser.rejected,"Non-escaped wire text fails instead of corrupting split UTF-8")
  }
  function test_inactive_owner_drops_partial_buffer_and_late_bytes() {
    var parser = createTemporaryObject(component,testCase)
    parser.push('{"partial":')
    verify(parser.pending.length > 0)
    parser.accepting = false
    compare(parser.pending,"")
    parser.push("x".repeat(1000))
    compare(parser.pending,"")
    compare(parser.bytes,0)
  }
}
