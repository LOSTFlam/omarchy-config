import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ryrobes.beatbar"

  readonly property var spectrum: bar && bar.shell
    ? bar.shell.serviceFor(moduleName)
    : null
  readonly property int configuredWidth: Math.max(72, Math.min(220,
    Number(setting("width", 112)) || 112))
  readonly property int configuredGain: Math.max(40, Math.min(250,
    Number(setting("gain", 100)) || 100))
  readonly property real visualGain: configuredGain / 100
  readonly property bool auroraPulse: setting("auroraPulse", true) === true
  readonly property bool showIdleLine: setting("showIdleLine", true) === true
  readonly property string mode: {
    var value = String(setting("mode", "Garden"))
    return ["Garden", "Mirror", "Aurora"].indexOf(value) >= 0 ? value : "Garden"
  }
  readonly property string bassMotion: {
    var value = String(setting("bassMotion", "Subtle"))
    return ["Off", "Subtle", "Loose"].indexOf(value) >= 0 ? value : "Subtle"
  }

  readonly property color themeForeground: bar ? bar.barForeground : Color.foreground
  readonly property color themeAccent: Color.accent
  readonly property color themeMuted: Color.muted
  readonly property color themeUrgent: Color.urgent

  property real beatGlow: 0
  property real kickEnergy: 0
  property real shakePhase: 0
  property real pulsePosition: 1
  property real pulseEnergy: 0

  readonly property real bassMotionScale: bassMotion === "Loose" ? 2.4
    : bassMotion === "Subtle" ? 1.15 : 0
  readonly property real shakeX: Math.sin(shakePhase) * kickEnergy * bassMotionScale
  readonly property real shakeY: Math.sin(shakePhase * 1.7 + 0.5)
    * kickEnergy * bassMotionScale * 0.42
  readonly property real kickScale: 1 + kickEnergy * bassMotionScale * 0.006

  implicitWidth: vertical ? barSize : Style.spaceReal(configuredWidth)
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value))
  }

  function mixColor(from, to, amount) {
    var t = clamp(amount, 0, 1)
    return Qt.rgba(
      from.r + (to.r - from.r) * t,
      from.g + (to.g - from.g) * t,
      from.b + (to.b - from.b) * t,
      from.a + (to.a - from.a) * t)
  }

  function withAlpha(color, alpha) {
    return Qt.rgba(color.r, color.g, color.b, clamp(alpha, 0, 1))
  }

  function scaledBands() {
    var source = spectrum && Array.isArray(spectrum.bands) ? spectrum.bands : []
    var values = []
    for (var i = 0; i < source.length; i++)
      values.push(clamp(Number(source[i] || 0) * visualGain, 0, 1))
    return values
  }

  function frequencyColor(index, count, value) {
    var center = (count - 1) / 2
    var distance = count > 1 ? Math.abs(index - center) / center : 0
    var base = mixColor(themeAccent, themeForeground, Math.pow(distance, 0.72))
    base = mixColor(themeMuted, base, 0.42 + value * 0.58)
    var heat = clamp((value - 0.68) / 0.32 + beatGlow * 0.45, 0, 1)
    return mixColor(base, themeUrgent, heat)
  }

  function persist(values) {
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    for (var key in values) entry[key] = values[key]
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function cycleMode() {
    var modes = ["Garden", "Mirror", "Aurora"]
    persist({ mode: modes[(modes.indexOf(mode) + 1) % modes.length] })
  }

  function adjustGain(direction) {
    var next = clamp(configuredGain + direction * 10, 40, 250)
    if (next !== configuredGain) persist({ gain: next })
  }

  function paintIdle(context, width, height) {
    if (!showIdleLine) return
    context.fillStyle = String(withAlpha(themeMuted, 0.34))
    context.fillRect(0, Math.floor(height / 2), width, 1)
  }

  function paintGarden(context, values, width, height) {
    var count = values.length
    if (count === 0) {
      paintIdle(context, width, height)
      return
    }
    var gap = Math.max(1, Math.floor(width / count * 0.24))
    var barWidth = Math.max(1, (width - gap * (count - 1)) / count)
    var floorY = height - 2
    var maximum = Math.max(1, height - 5)
    var alive = false

    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var barHeight = Math.max(value > 0 ? 1 : 0, value * maximum)
      var x = i * (barWidth + gap)
      context.fillStyle = String(frequencyColor(i, count, value))
      context.fillRect(x, floorY - barHeight, barWidth, barHeight)
    }
    if (!alive) paintIdle(context, width, height)
  }

  function paintMirror(context, values, width, height) {
    var count = values.length
    if (count === 0) {
      paintIdle(context, width, height)
      return
    }
    var gap = Math.max(1, Math.floor(width / count * 0.22))
    var barWidth = Math.max(1, (width - gap * (count - 1)) / count)
    var centerY = height / 2
    var maximum = Math.max(1, height / 2 - 2)
    var alive = false

    context.fillStyle = String(withAlpha(themeMuted, 0.22))
    context.fillRect(0, Math.floor(centerY), width, 1)
    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var halfHeight = Math.max(value > 0 ? 0.5 : 0, value * maximum)
      var x = i * (barWidth + gap)
      context.fillStyle = String(frequencyColor(i, count, value))
      context.fillRect(x, centerY - halfHeight, barWidth, halfHeight * 2)
    }
    if (!alive && !showIdleLine) context.clearRect(0, 0, width, height)
  }

  function paintAurora(context, values, width, height) {
    var count = values.length
    if (count < 2) {
      paintIdle(context, width, height)
      return
    }
    var maximum = Math.max(1, height - 5)
    var floorY = height - 2
    var alive = false
    var gradient = context.createLinearGradient(0, 0, width, 0)
    gradient.addColorStop(0, String(withAlpha(themeMuted, 0.32)))
    gradient.addColorStop(0.5, String(withAlpha(mixColor(themeAccent, themeUrgent, beatGlow * 0.5), 0.78)))
    gradient.addColorStop(1, String(withAlpha(themeForeground, 0.36)))

    context.beginPath()
    context.moveTo(0, floorY)
    for (var i = 0; i < count; i++) {
      var value = values[i]
      if (value > 0.012) alive = true
      var x = i * width / (count - 1)
      var y = floorY - value * maximum
      context.lineTo(x, y)
    }
    context.lineTo(width, floorY)
    context.closePath()
    context.fillStyle = gradient
    context.fill()

    if (auroraPulse && pulseEnergy > 0.001) {
      var position = clamp(pulsePosition, 0, 1)
      var radius = 0.11
      var leadingEdge = Math.max(0, position - radius)
      var trailingEdge = Math.min(1, position + radius)
      var transparent = String(withAlpha(themeAccent, 0))
      var pulseColor = mixColor(themeForeground, themeUrgent,
        0.12 + pulseEnergy * 0.38)
      var pulseGradient = context.createLinearGradient(0, 0, width, 0)

      pulseGradient.addColorStop(0, transparent)
      if (leadingEdge > 0) pulseGradient.addColorStop(leadingEdge, transparent)
      pulseGradient.addColorStop(position,
        String(withAlpha(pulseColor, 0.22 + pulseEnergy * 0.7)))
      if (trailingEdge < 1) pulseGradient.addColorStop(trailingEdge, transparent)
      pulseGradient.addColorStop(1, transparent)

      context.save()
      context.clip()
      context.fillStyle = pulseGradient
      context.fillRect(0, 0, width, height)
      context.restore()
    }

    context.beginPath()
    for (var j = 0; j < count; j++) {
      var px = j * width / (count - 1)
      var py = floorY - values[j] * maximum
      if (j === 0) context.moveTo(px, py)
      else context.lineTo(px, py)
    }
    context.strokeStyle = String(mixColor(themeAccent, themeUrgent, beatGlow * 0.65))
    context.lineWidth = 1
    context.stroke()

    if (!alive) {
      context.clearRect(0, 0, width, height)
      paintIdle(context, width, height)
    }
  }

  function paintSpectrum(context, width, height) {
    var values = scaledBands()
    if (mode === "Mirror") paintMirror(context, values, width, height)
    else if (mode === "Aurora") paintAurora(context, values, width, height)
    else paintGarden(context, values, width, height)
  }

  onModeChanged: {
    if (mode !== "Aurora") {
      pulseTravel.stop()
      pulseDecay.stop()
      pulseEnergy = 0
    }
    visualization.requestPaint()
  }
  onAuroraPulseChanged: {
    if (!auroraPulse) {
      pulseTravel.stop()
      pulseDecay.stop()
      pulseEnergy = 0
    }
    visualization.requestPaint()
  }
  onBassMotionChanged: {
    if (bassMotion === "Off") {
      kickPhase.stop()
      kickDecay.stop()
      kickEnergy = 0
      shakePhase = 0
    }
    visualization.requestPaint()
  }
  onVisualGainChanged: visualization.requestPaint()
  onShowIdleLineChanged: visualization.requestPaint()
  onThemeForegroundChanged: visualization.requestPaint()
  onThemeAccentChanged: visualization.requestPaint()
  onThemeMutedChanged: visualization.requestPaint()
  onThemeUrgentChanged: visualization.requestPaint()

  Connections {
    target: root.spectrum
    function onBandsChanged() { visualization.requestPaint() }
    function onBeat(strength) {
      root.beatGlow = Math.max(root.beatGlow, Number(strength) || 0)
      beatDecay.from = root.beatGlow
      beatDecay.restart()

      if (root.mode === "Aurora" && root.auroraPulse) {
        pulseDecay.stop()
        root.pulseEnergy = Math.max(root.pulseEnergy,
          root.clamp((Number(strength) || 0) * 1.15, 0, 1))
        if (!pulseTravel.running) {
          root.pulsePosition = 0
          pulseTravel.restart()
        }
        pulseDecay.from = root.pulseEnergy
        pulseDecay.restart()
      }

      if (root.bassMotion !== "Off") {
        kickPhase.stop()
        kickDecay.stop()
        root.kickEnergy = Math.max(root.kickEnergy, Number(strength) || 0)
        root.shakePhase = 0
        kickPhase.restart()
        kickDecay.from = root.kickEnergy
        kickDecay.restart()
      }
      visualization.requestPaint()
    }
  }

  NumberAnimation {
    id: beatDecay
    target: root
    property: "beatGlow"
    to: 0
    duration: 180
    easing.type: Easing.OutCubic
    onRunningChanged: visualization.requestPaint()
  }

  NumberAnimation {
    id: kickPhase
    target: root
    property: "shakePhase"
    from: 0
    to: Math.PI * 6
    duration: 180
    easing.type: Easing.OutQuad
  }

  NumberAnimation {
    id: kickDecay
    target: root
    property: "kickEnergy"
    to: 0
    duration: 200
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: pulseTravel
    target: root
    property: "pulsePosition"
    from: 0
    to: 1
    duration: 520
    easing.type: Easing.InOutQuad
  }

  NumberAnimation {
    id: pulseDecay
    target: root
    property: "pulseEnergy"
    to: 0
    duration: 560
    easing.type: Easing.OutQuad
  }

  onBeatGlowChanged: visualization.requestPaint()
  onShakePhaseChanged: visualization.requestPaint()
  onKickEnergyChanged: visualization.requestPaint()
  onPulsePositionChanged: visualization.requestPaint()
  onPulseEnergyChanged: visualization.requestPaint()

  Canvas {
    id: visualization
    anchors.fill: parent
    antialiasing: true

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var context = getContext("2d")
      context.clearRect(0, 0, width, height)
      if (width <= 0 || height <= 0) return

      context.save()
      context.translate(root.shakeX, root.shakeY)
      context.translate(width / 2, height / 2)
      context.scale(root.kickScale, root.kickScale)
      context.translate(-width / 2, -height / 2)

      if (root.vertical) {
        context.translate(width, 0)
        context.rotate(Math.PI / 2)
        root.paintSpectrum(context, height, width)
      } else {
        root.paintSpectrum(context, width, height)
      }
      context.restore()
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: root.cycleMode()
    onWheel: function(wheel) {
      root.adjustGain(wheel.angleDelta.y >= 0 ? 1 : -1)
      wheel.accepted = true
    }
  }
}
