import QtQuick
import QtQuick.Controls
import QtTest

import ".."

TestCase {
  id: testCase
  name: "Scrolling"
  when: windowShown
  width: 320
  height: 240

  ListView {
    id: list
    anchors.fill: parent
    model: 100
    delegate: Rectangle {
      required property int index
      width: 320
      height: 66
    }

    FastScrollHandler {
      id: fastScroll
      parent: list
      flickable: list
    }
  }

  AutoScrollController {
    id: autoScroll
    flickable: list
    boundsHelper: fastScroll
    linesPerSecond: 0.5
    pixelsPerLine: 40
    maximumFrameMs: 2000
    clockEnabled: false
  }

  Flickable {
    id: delayedFlick
    x: testCase.width + 220
    width: 180
    height: 100
    contentWidth: width
    contentHeight: delayedContent.height

    Rectangle {
      id: delayedContent
      width: delayedFlick.width
      height: 0
    }

    FastScrollHandler {
      id: delayedFastScroll
      parent: delayedFlick
      flickable: delayedFlick
    }
  }

  AutoScrollController {
    id: delayedAutoScroll
    flickable: delayedFlick
    boundsHelper: delayedFastScroll
    clockEnabled: false
  }

  ScrollView {
    id: scrollView
    x: testCase.width + 20
    width: 180
    height: 100

    Rectangle {
      width: scrollView.availableWidth
      implicitHeight: 600
      height: implicitHeight
    }
  }

  FastScrollHandler {
    id: scrollViewFastScroll
    parent: scrollView.contentItem
    flickable: scrollView.contentItem
  }

  SignalSpy {
    id: scrollSpy
    target: fastScroll
    signalName: "scrolled"
  }

  SignalSpy {
    id: endSpy
    target: autoScroll
    signalName: "reachedEnd"
  }

  function init() {
    autoScroll.pause()
    delayedAutoScroll.pause()
    delayedContent.height = 0
    delayedFlick.contentY = delayedFlick.originY
    fastScroll.stopAnimation()
    fastScroll.notchAnimationMs = 180
    list.positionViewAtBeginning()
    scrollSpy.clear()
    endSpy.clear()
    wait(1)
  }

  function test_deltaIsQuadrupled() {
    compare(fastScroll.parent, list)
    compare(fastScroll.scrollDistance(14, 0), 56)
    compare(fastScroll.scrollDistance(0, -120),
      -fastScroll.mouseWheelStep * 4)
  }

  function test_scrollApplicationMovesFourTimesTheBaseStep() {
    var expected = fastScroll.mouseWheelStep * 4
    compare(fastScroll.scrollByDeltas(0, -120), expected)
    compare(list.contentY, expected)
    compare(scrollSpy.count, 1)
  }

  function test_scrollIsBounded() {
    compare(fastScroll.boundedContentY(-500), 0)
    compare(fastScroll.boundedContentY(100000), list.contentHeight - list.height)
  }

  function test_scrollViewOverlayDoesNotBecomeScrollableContent() {
    compare(scrollViewFastScroll.parent, scrollView.contentItem)
    compare(scrollViewFastScroll.flickable.contentHeight, 600)
    compare(scrollViewFastScroll.scrollByDeltas(0, -120),
      scrollViewFastScroll.mouseWheelStep * 4)
    compare(scrollViewFastScroll.flickable.contentHeight, 600)
  }

  function test_autoScrollUsesRenderedLinesAndSharedBounds() {
    autoScroll.running = true
    autoScroll.lastTickMs = 1000
    compare(autoScroll.advanceTo(1500), 10)
    compare(list.contentY, 10)
    verify(autoScroll.running)
  }

  function test_autoScrollStopsAndSignalsAtTheEnd() {
    list.contentY = fastScroll.boundedContentY(100000) - 5
    autoScroll.running = true
    autoScroll.lastTickMs = 1000
    autoScroll.advanceTo(2000)
    compare(list.contentY, fastScroll.boundedContentY(100000))
    verify(!autoScroll.running)
    compare(endSpy.count, 1)
  }

  function test_playbackPositionKeepsEstimatedLineAboveViewportMiddle() {
    compare(autoScroll.playbackFraction(100, 200), 0.5)
    compare(autoScroll.playbackFraction(-5, 200), 0)
    compare(autoScroll.playbackFraction(250, 200), 1)
    compare(autoScroll.playbackFraction(100, 0), 0)

    var contextPixels = list.height * 0.4
    var estimatedLineY = list.contentHeight * 0.5
    var expected = estimatedLineY - contextPixels
    var actual = autoScroll.seekToPlaybackPosition(100, 200, 0.4)
    verify(Math.abs(actual - expected) < 0.01)
    verify(Math.abs(list.contentY - expected) < 0.01)
    verify(Math.abs(estimatedLineY - list.contentY - contextPixels) < 0.01)
  }

  function test_playbackSafetyAdaptsToRenderedLyricLength() {
    // The same visual context represents fewer seconds in a lyric-dense song.
    var sparse = autoScroll.playbackSafetySeconds(284, 2400, 600, 0.4)
    var dense = autoScroll.playbackSafetySeconds(284, 7200, 600, 0.4)
    compare(sparse, 28.4)
    verify(Math.abs(dense - (284 / 30)) < 0.0001)

    // At 2:00 in a 4:44 dense song, the estimate remains 40% down the view.
    var elapsedFraction = autoScroll.playbackFraction(120, 284)
    var estimatedLineY = list.contentHeight * elapsedFraction
    autoScroll.seekToPlaybackPosition(120, 284, 0.4)
    verify(Math.abs(estimatedLineY - list.contentY - list.height * 0.4) < 0.01)
  }

  function test_playbackPositionWaitsForLyricsToFinishLayout() {
    delayedAutoScroll.seekToPlaybackPosition(100, 200, 0.4)
    verify(delayedAutoScroll.playbackSeekPending)
    compare(delayedFlick.contentY, delayedFlick.originY)

    delayedContent.height = 500
    wait(20)
    verify(!delayedAutoScroll.playbackSeekPending)
    verify(Math.abs(delayedFlick.contentY - 210) < 0.01)
  }

  function test_pixelDeltasStayImmediateWhenAnimated() {
    compare(fastScroll.scrollByDeltasAnimated(-14, 0), 56)
    compare(list.contentY, 56)
    verify(!fastScroll.animating)
  }

  function test_notchScrollAnimatesTowardTheTarget() {
    fastScroll.notchAnimationMs = 80
    var expected = fastScroll.mouseWheelStep * 4
    compare(fastScroll.scrollByDeltasAnimated(0, -120), expected)
    verify(list.contentY <= expected)
    tryVerify(function() {
      return Math.abs(list.contentY - expected) < 0.5
    })
    verify(!fastScroll.animating)
  }

  function test_stackedNotchesKeepASingleTarget() {
    fastScroll.notchAnimationMs = 120
    var step = fastScroll.mouseWheelStep * 4
    compare(fastScroll.scrollByDeltasAnimated(0, -120), step)
    compare(fastScroll.scrollByDeltasAnimated(0, -120), step * 2)
    tryVerify(function() {
      return Math.abs(list.contentY - step * 2) < 0.5
    })
  }
}
