import QtQuick
import QtQuick.Particles
import QtQuick.Effects
import qs.Commons

// Per-screen weather overlay for the Osaka Jade city wallpaper.
//
// Everything below the vignette is gated on a mood being active, and every
// animation and ParticleSystem stops (not just hides) when its mood is off --
// with all three toggles down this item costs nothing but the vignette.
//
// Depth trick used throughout: two passes of the same effect, one small/slow/
// faint for the far plane and one large/fast/bright for the near plane.
Item {
  id: fx

  property var st: null                  // WeatherState
  property real pointerX: 0.5            // normalised pointer, for parallax
  property real pointerY: 0.5

  readonly property bool rainOn: st ? st.rainOn : false
  readonly property bool dayOn: st ? st.dayOn : false
  readonly property bool nightOn: st ? st.nightOn : false
  readonly property bool thunderOn: st ? st.thunderOn : false
  readonly property bool fogOn: st ? st.fogOn : false
  readonly property color hazeColor: st ? st.hazeColor : "#9aa8a4"
  readonly property real amount: st ? st.amount : 1.0
  readonly property real wind: st ? st.wind : 0.0
  readonly property bool grainOn: st ? (st.fxEnabled && st.grain) : false

  // The shared low-rate clock, in seconds. Everything on this layer that moves
  // slowly enough to not need a frame of its own is a binding on it rather
  // than an animation of its own -- see WeatherState for why. It stops when
  // the desktop is covered, which freezes all of them at once.
  readonly property real clock: st ? st.slowClock : 0
  readonly property bool awake: st ? st.desktopVisible : true

  // Sky placement, as fractions of this panel. See WeatherState for what each
  // one means; every layer below derives its geometry from these rather than
  // from constants tuned to one photograph.
  readonly property real horizon: st ? st.horizon : 0.34
  readonly property real skyLeft: st ? st.skyLeft : 0.16
  readonly property real groundLevel: st ? st.groundLevel : 0.42
  readonly property real mistY: st ? st.mistY : 0.30
  readonly property real mistBand: st ? st.mistHeight : 0.34
  readonly property real discX: st ? (dayOn ? st.sunX : st.moonX) : 0.60
  readonly property real discY: st ? (dayOn ? st.sunY : st.moonY) : 0.14
  readonly property real discSize: st ? (dayOn ? st.sunSize : st.moonSize) : 0.95
  readonly property real nearBand: (1 - groundLevel) * 0.8

  // Two kinds of colour here, and they are not the same kind.
  //
  // Sunlight is warm and moonlight is cold on anyone's wallpaper, so the sky
  // tints and the sun and moon discs stay physical -- theming those would make
  // a sunrise the wrong colour to match a terminal palette.
  //
  // What follows the theme is the life in the scene: fireflies take the accent,
  // and rain takes an ambient tint off the foreground, because rain is water
  // and picks up whatever light is around it.
  readonly property color sparkColor: Color.accent
  readonly property color rainFar: Color.foreground
  readonly property color rainNear: Qt.lighter(Color.foreground, 1.25)
  readonly property color moteColor: "#F7E8B2"   // sunlit dust is warm anywhere

  clip: true

  // Rain keeps its system running for one particle lifetime after the mood is
  // switched off, so the last drops fall out of frame instead of freezing
  // mid-air -- stopping a ParticleSystem freezes its final frame rather than
  // clearing it. The fireflies and motes need none of this: they fade on their
  // own opacity and are gone when it reaches zero.
  property bool rainRunning: false
  onRainOnChanged: if (rainOn) { rainTail.stop(); rainRunning = true } else rainTail.restart()
  Timer { id: rainTail; interval: 3200; onTriggered: if (!fx.rainOn) fx.rainRunning = false }
  Component.onCompleted: rainRunning = rainOn

  // ------------------------------------------------------------------ sky --
  // Directional light the uniform colour grade can't express: warm from above
  // for day, cold from above plus a dark floor for night, flat murk for rain.
  Rectangle {
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.dayOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
    gradient: Gradient {
      GradientStop { position: 0.00; color: "#59ffcf87" }
      GradientStop { position: 0.32; color: "#2effc98a" }
      GradientStop { position: 0.62; color: "#0cffb877" }
      GradientStop { position: 1.00; color: "#00ffb877" }
    }
  }

  Rectangle {
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.nightOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
    gradient: Gradient {
      GradientStop { position: 0.00; color: "#5c0a1730" }
      GradientStop { position: 0.40; color: "#1e0b1c36" }
      GradientStop { position: 0.72; color: "#00000000" }
      GradientStop { position: 1.00; color: "#4a04080e" }
    }
  }

  Rectangle {
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.rainOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
    gradient: Gradient {
      GradientStop { position: 0.00; color: "#6b0c2630" }
      GradientStop { position: 0.45; color: "#2a10303a" }
      GradientStop { position: 1.00; color: "#12142c30" }
    }
  }

  // ------------------------------------------------------- sun / moon disc --
  // Parked over the gap between the ridge line and the tower cluster, which is
  // the only patch of open sky in the photograph.
  Item {
    id: luminary
    visible: opacity > 0.001
    opacity: (fx.dayOn || fx.nightOn) ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 1100; easing.type: Easing.InOutCubic } }

    readonly property real span: fx.height * fx.discSize
    width: span
    height: span
    x: fx.width * fx.discX - span / 2 + fx.parallaxX * 1.6
    y: fx.height * fx.discY - span / 2 + fx.parallaxY * 1.6
    Behavior on x { NumberAnimation { duration: 1100; easing.type: Easing.InOutCubic } }
    Behavior on y { NumberAnimation { duration: 1100; easing.type: Easing.InOutCubic } }

    layer.enabled: luminary.visible && width > 8 && height > 8
    layer.smooth: true
    layer.effect: MultiEffect {
      colorization: 1.0
      colorizationColor: fx.dayOn ? "#ffd98a" : "#bfe4ff"
      brightness: fx.dayOn ? 0.25 : 0.05
    }

    Image {
      anchors.fill: parent
      source: Qt.resolvedUrl("assets/glow.png")
      fillMode: Image.Stretch
      smooth: true
      opacity: fx.dayOn ? 0.55 : 0.30
      Behavior on opacity { NumberAnimation { duration: 1100 } }
    }

    // Tight core so there is a disc inside the halo, not just a smudge.
    Image {
      anchors.centerIn: parent
      width: parent.width * (fx.dayOn ? 0.22 : 0.17)
      height: width
      source: Qt.resolvedUrl("assets/glow.png")
      fillMode: Image.Stretch
      smooth: true
      opacity: fx.dayOn ? 0.85 : 0.55
      scale: 1 + luminary.pulse
      Behavior on opacity { NumberAnimation { duration: 1100 } }
    }

    readonly property real pulse:
      visible ? 0.025 + 0.025 * Math.sin(fx.clock * 0.5560) : 0
  }

  // ------------------------------------------------------------- god rays --
  // Full-size on purpose: layer.effect renders into a texture the size of the
  // item it is on, so a small anchor item here would clip the whole fan away.
  // The fan hangs off a zero-sized origin child instead.
  Item {
    id: rays
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.dayOn ? 0.8 : 0
    Behavior on opacity { NumberAnimation { duration: 1400; easing.type: Easing.InOutCubic } }

    layer.enabled: rays.visible && width > 0 && height > 0
    layer.smooth: true
    layer.effect: MultiEffect {
      colorization: 1.0
      colorizationColor: "#ffe0a4"
      brightness: 0.1
    }

    readonly property real sway: visible ? Math.sin(fx.clock * 0.1396) : 0

    Item {
      id: rayOrigin
      width: 0
      height: 0
      x: fx.width * fx.discX + fx.parallaxX * 2.2
      y: fx.height * fx.discY * 0.45 + fx.parallaxY * 2.2

      Repeater {
        model: 7
        Image {
          required property int index
          source: Qt.resolvedUrl("assets/ray.png")
          smooth: true
          width: fx.height * (0.38 + 0.16 * (index % 3))
          height: fx.height * 1.45
          x: -width / 2
          y: 0
          transformOrigin: Item.Top
          rotation: -34 + index * 11.5 + rays.sway * 2.4
          readonly property real beat: 6.2832 / (11.3 + index * 1.6)
          opacity: rays.visible
            ? 0.33 + 0.17 * Math.sin(fx.clock * beat + index * 1.7)
            : 0
        }
      }
    }
  }

  // ----------------------------------------------------------------- stars --
  // Confined to the upper sky and faded out over the left third, where the
  // foreground house eats the sky in the source image.
  Item {
    id: stars
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.nightOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 1600; easing.type: Easing.InOutCubic } }

    // Deterministic hash so the constellation is identical across reloads and
    // across monitors of the same size.
    function rnd(i, salt) {
      var v = Math.sin(i * 127.1 + salt * 311.7) * 43758.5453
      return v - Math.floor(v)
    }

    Repeater {
      model: stars.visible ? 90 : 0
      Image {
        required property int index
        readonly property real px: stars.rnd(index, 1)
        readonly property real py: stars.rnd(index, 2)
        readonly property real mag: stars.rnd(index, 3)

        source: Qt.resolvedUrl("assets/star.png")
        smooth: true
        width: 6 + mag * 12
        height: width
        x: px * fx.width - width / 2
        y: py * py * fx.height * fx.horizon - height / 2

        // Fade toward the horizon and into the foreground rooftops on the left.
        readonly property real reach:
          Math.max(0, 1 - py * py * 1.15) *
          Math.min(1, Math.max(0, (px - fx.skyLeft) / 0.20))

        // Ninety stars used to be ninety infinite animations, each waking the
        // scene graph every frame to move an opacity by a thousandth. They are
        // now ninety bindings on one clock, sampled together.
        readonly property real hi: 0.85 * reach * (0.35 + mag * 0.65)
        readonly property real lo: 0.12 * reach
        readonly property real beat:
          6.2832 / (3.2 + mag * 2.6 + stars.rnd(index, 5) * 3.4)
        opacity: stars.visible
          ? lo + (hi - lo) * (0.5 + 0.5 * Math.sin(fx.clock * beat + stars.rnd(index, 4) * 6.2832))
          : 0
      }
    }
  }

  // ------------------------------------------------------------------ mist --
  // Two seamless bands crossing at different speeds and scales. Always on at a
  // whisper (the city is already hazy); rain thickens it considerably.
  Item {
    id: mist
    anchors.fill: parent
    visible: opacity > 0.001
    // Fog is its own toggle now. Rain still brings some haze with it, because
    // rain without any is a sprite over a dry picture.
    opacity: (fx.fogOn || fx.rainOn) ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 1400; easing.type: Easing.InOutCubic } }

    // far band -- sits on the city, drifts right
    Image {
      id: mistFar
      // White mist over a coloured scene reads as a grey stripe; tinted
      // with the picture's own haze it sits inside the image.
      layer.enabled: mist.visible && width > 0 && height > 0
      layer.effect: MultiEffect {
        colorization: 1.0
        colorizationColor: fx.hazeColor
      }
      source: Qt.resolvedUrl("assets/mist.png")
      fillMode: Image.TileHorizontally
      smooth: true
      readonly property int tile: Math.max(600, Math.round(fx.width * 0.85))
      sourceSize.width: tile
      sourceSize.height: Math.max(1, Math.round(fx.height * fx.mistBand))
      width: fx.width + tile
      height: Math.round(fx.height * fx.mistBand)
      y: fx.height * fx.mistY
      opacity: fx.fogOn ? 0.34 : 0.15
      Behavior on opacity { NumberAnimation { duration: 1400 } }
      x: -tile + tile * ((fx.clock % 96) / 96)
    }

    // near band -- lower, larger, drifts left, so the two shear against each other
    Image {
      id: mistNear
      // White mist over a coloured scene reads as a grey stripe; tinted
      // with the picture's own haze it sits inside the image.
      layer.enabled: mist.visible && width > 0 && height > 0
      layer.effect: MultiEffect {
        colorization: 1.0
        colorizationColor: fx.hazeColor
      }
      source: Qt.resolvedUrl("assets/mist.png")
      fillMode: Image.TileHorizontally
      smooth: true
      readonly property int tile: Math.max(900, Math.round(fx.width * 1.45))
      sourceSize.width: tile
      sourceSize.height: Math.max(1, Math.round(fx.height * fx.nearBand))
      width: fx.width + tile
      height: Math.round(fx.height * fx.nearBand)
      y: fx.height * (fx.groundLevel + (1 - fx.groundLevel) * 0.17)
      opacity: fx.fogOn ? 0.26 : 0.11
      Behavior on opacity { NumberAnimation { duration: 1400 } }
      x: -tile * ((fx.clock % 141) / 141)
    }
  }

  // ------------------------------------------------------------------ rain --
  ParticleSystem {
    id: rainSys
    // `paused` stops the simulation but not the frame requests -- with the
    // desktop covered it measured no cheaper than running. Stopping it does,
    // and the curtain refills in under a second (a drop lives 2.6s and clears
    // the screen in half that), so nothing is visibly missing coming back.
    running: fx.rainRunning && fx.awake
    anchors.fill: parent
  }

  // far curtain: short, slow, dim, dense
  Emitter {
    system: rainSys
    group: "far"
    enabled: fx.rainOn
    x: -fx.width * 0.30
    y: -160
    width: fx.width * 1.6
    height: 20
    emitRate: Math.round(270 * fx.amount)
    lifeSpan: 2600
    lifeSpanVariation: 500
    size: 26
    sizeVariation: 8
    velocity: AngleDirection {
      angle: 96 + fx.wind * 16
      angleVariation: 2.0
      magnitude: 900
      magnitudeVariation: 220
    }
    acceleration: PointDirection { y: 180 }
  }

  ImageParticle {
    system: rainSys
    groups: ["far"]
    opacity: fx.rainOn ? 1 : 0
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 2600; easing.type: Easing.InOutCubic } }
    source: Qt.resolvedUrl("assets/raindrop.png")
    autoRotation: true
    color: fx.rainFar
    colorVariation: 0.15
    alpha: 0.22
    alphaVariation: 0.11
  }

  // near curtain: long, fast, bright, sparse
  Emitter {
    system: rainSys
    group: "near"
    enabled: fx.rainOn
    x: -fx.width * 0.30
    y: -220
    width: fx.width * 1.6
    height: 20
    emitRate: Math.round(95 * fx.amount)
    lifeSpan: 1700
    lifeSpanVariation: 260
    size: 92
    sizeVariation: 30
    velocity: AngleDirection {
      angle: 95 + fx.wind * 18
      angleVariation: 1.6
      magnitude: 1750
      magnitudeVariation: 380
    }
    acceleration: PointDirection { y: 300 }
  }

  ImageParticle {
    system: rainSys
    groups: ["near"]
    opacity: fx.rainOn ? 1 : 0
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 2600; easing.type: Easing.InOutCubic } }
    source: Qt.resolvedUrl("assets/raindrop.png")
    autoRotation: true
    color: fx.rainNear
    colorVariation: 0.10
    alpha: 0.38
    alphaVariation: 0.16
  }

  // splash pops along the bottom edge -- what actually sells "it is raining"
  Emitter {
    system: rainSys
    group: "splash"
    enabled: fx.rainOn
    x: 0
    y: fx.height - 26
    width: fx.width
    height: 22
    emitRate: Math.round(55 * fx.amount)
    lifeSpan: 520
    lifeSpanVariation: 160
    size: 3
    endSize: 26
    velocity: AngleDirection { angle: 270; angleVariation: 55; magnitude: 48; magnitudeVariation: 26 }
  }

  ImageParticle {
    system: rainSys
    groups: ["splash"]
    opacity: fx.rainOn ? 1 : 0
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.InOutCubic } }
    source: Qt.resolvedUrl("assets/glow.png")
    color: fx.rainFar
    colorVariation: 0.2
    alpha: 0.18
    alphaVariation: 0.10
  }

  // ------------------------------------------------------------- lightning --
  Item {
    id: storm
    anchors.fill: parent
    visible: fx.thunderOn

    Rectangle {
      id: bolt
      anchors.fill: parent
      color: "#eafdf6"
      opacity: 0
    }

    // A second, slower glow low on the horizon: the strike is somewhere behind
    // the towers, not on top of the camera.
    Rectangle {
      id: skyGlow
      anchors.fill: parent
      opacity: 0
      gradient: Gradient {
        GradientStop { position: 0.00; color: "#00ffffff" }
        GradientStop { position: 0.34; color: "#ffdff9f0" }
        GradientStop { position: 0.70; color: "#00ffffff" }
      }
    }

    SequentialAnimation {
      id: strike
      ParallelAnimation {
        SequentialAnimation {
          NumberAnimation { target: bolt; property: "opacity"; to: 0.34; duration: 45 }
          NumberAnimation { target: bolt; property: "opacity"; to: 0.04; duration: 90 }
          NumberAnimation { target: bolt; property: "opacity"; to: 0.26; duration: 60 }
          NumberAnimation { target: bolt; property: "opacity"; to: 0.00; duration: 420; easing.type: Easing.OutCubic }
        }
        SequentialAnimation {
          NumberAnimation { target: skyGlow; property: "opacity"; to: 0.30; duration: 70 }
          NumberAnimation { target: skyGlow; property: "opacity"; to: 0.00; duration: 900; easing.type: Easing.OutCubic }
        }
      }
    }

    Timer {
      running: storm.visible && fx.awake
      // Poisson-ish: re-roll the gap after every strike so it never feels metronomic.
      interval: 9000 + Math.round(Math.random() * 34000)
      repeat: true
      onTriggered: {
        strike.restart()
        interval = 9000 + Math.round(Math.random() * 34000)
      }
    }
  }

  // ------------------------------------------------------------ fireflies --
  // Jade spirits over the rooftops. Sparse and slow on purpose -- these are
  // the thing you notice on the third glance, not the first.
  //
  // Drawn rather than simulated. A ParticleSystem steps its whole simulation
  // on every frame whether or not anything is moving far, and measured at
  // ~20% CPU here to carry sixty specks across a rooftop at 5px a second --
  // the same cost at intensity 0, when it emits nothing at all. These follow
  // the shared clock instead: each speck owns a deterministic loop of
  // position and fade, so the flight is reproducible, the seam is hidden at
  // zero opacity, and nothing is computed between ticks.
  Item {
    id: flies
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.nightOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 3400; easing.type: Easing.InOutCubic } }

    function rnd(i, salt) {
      var v = Math.sin(i * 127.1 + salt * 311.7) * 43758.5453
      return v - Math.floor(v)
    }

    readonly property real bandY: fx.height * fx.groundLevel
    readonly property real bandH: fx.height * (1 - fx.groundLevel)

    Repeater {
      model: flies.visible ? Math.max(6, Math.round(64 * fx.amount)) : 0
      Image {
        required property int index

        // One life: fade up, wander, fade down, begin again elsewhere.
        readonly property real span: 11 + flies.rnd(index, 6) * 6
        readonly property real u: {
          var t = fx.clock + flies.rnd(index, 7) * span
          return (t % span) / span
        }
        // Re-seed the resting place once per life, so a speck does not return
        // to the same spot every time it lights up.
        readonly property int life: Math.floor((fx.clock + flies.rnd(index, 7) * span) / span)
        readonly property real px: flies.rnd(index + life * 37, 1)
        readonly property real py: flies.rnd(index + life * 37, 2)

        source: Qt.resolvedUrl("assets/glow.png")
        smooth: true
        width: 5 + flies.rnd(index, 3) * 8
        height: width

        x: px * fx.width
           + 46 * Math.sin(fx.clock * (0.42 + flies.rnd(index, 4) * 0.38) + index)
           - width / 2
        y: flies.bandY + py * flies.bandH
           + 34 * Math.sin(fx.clock * (0.31 + flies.rnd(index, 5) * 0.29) + index * 1.7)
           - u * 34
           - height / 2

        opacity: Math.sin(Math.PI * u) * (0.55 + flies.rnd(index, 8) * 0.45)
      }
    }

    // The theme accent, so the spirits belong to whatever palette is set.
    layer.enabled: flies.visible && width > 0 && height > 0
    layer.effect: MultiEffect {
      colorization: 1.0
      colorizationColor: fx.sparkColor
    }
  }

  // ------------------------------------------------------------ dust motes --
  // Sunlit dust, on the same clock and for the same reason as the fireflies.
  Item {
    id: motes
    anchors.fill: parent
    visible: opacity > 0.001
    opacity: fx.dayOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 3400; easing.type: Easing.InOutCubic } }

    function rnd(i, salt) {
      var v = Math.sin(i * 269.5 + salt * 183.3) * 43758.5453
      return v - Math.floor(v)
    }

    Repeater {
      model: motes.visible ? Math.max(12, Math.round(150 * fx.amount)) : 0
      Image {
        required property int index

        readonly property real span: 13 + motes.rnd(index, 6) * 5
        readonly property real u: {
          var t = fx.clock + motes.rnd(index, 7) * span
          return (t % span) / span
        }
        readonly property int life: Math.floor((fx.clock + motes.rnd(index, 7) * span) / span)
        readonly property real px: motes.rnd(index + life * 53, 1)
        readonly property real py: motes.rnd(index + life * 53, 2)

        source: Qt.resolvedUrl("assets/glow.png")
        smooth: true
        width: 3 + motes.rnd(index, 3) * 5
        height: width

        // Up and slightly left, the way the emitter used to throw them.
        x: px * fx.width
           + 34 * Math.sin(fx.clock * (0.24 + motes.rnd(index, 4) * 0.2) + index)
           - u * 22
           - width / 2
        y: py * fx.height
           + 18 * Math.sin(fx.clock * (0.19 + motes.rnd(index, 5) * 0.17) + index * 2.3)
           - u * 165
           - height / 2

        opacity: Math.sin(Math.PI * u) * (0.30 + motes.rnd(index, 8) * 0.30)
      }
    }

    layer.enabled: motes.visible && width > 0 && height > 0
    layer.effect: MultiEffect {
      colorization: 1.0
      colorizationColor: fx.moteColor
    }
  }

  // ------------------------------------------------------------ film grain --
  Image {
    id: grain
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/grain.png")
    fillMode: Image.Tile
    smooth: false
    visible: fx.grainOn
    opacity: 0.030

    // Jitter the tile origin a few times a second so the grain crawls the way
    // film does instead of sitting there like a texture -- on the shared clock
    // rather than a timer of its own. Two ticks that are not in step dirty the
    // screen twice as often as one: grain and drift each cost ~8 points alone
    // and ~14 together, which is the whole of the difference.
    readonly property int step: Math.floor(fx.clock * 10)
    function jitter(salt) {
      var v = Math.sin(step * 12.9898 + salt * 78.233) * 43758.5453
      return -Math.round((v - Math.floor(v)) * 127)
    }
    x: jitter(1)
    y: jitter(2)
  }

  // -------------------------------------------------------------- vignette --
  Image {
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/vignette.png")
    fillMode: Image.Stretch
    smooth: true
    opacity: fx.rainOn ? 0.42 : (fx.nightOn ? 0.36 : (fx.dayOn ? 0.16 : 0.22))
    Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.InOutCubic } }
  }

  // ------------------------------------------------------------- parallax --
  // Shared with the photo layer below so the sun, rays and photo lean together.
  readonly property bool parallaxOn: st ? (st.fxEnabled && st.parallax) : false
  property real parallaxX: 0
  property real parallaxY: 0
  Behavior on parallaxX { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
  Behavior on parallaxY { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }

  onPointerXChanged: if (parallaxOn) parallaxX = (0.5 - pointerX) * fx.width * 0.012
  onPointerYChanged: if (parallaxOn) parallaxY = (0.5 - pointerY) * fx.height * 0.010
  onParallaxOnChanged: if (!parallaxOn) { parallaxX = 0; parallaxY = 0 }
}
