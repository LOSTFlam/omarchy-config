import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Shared, screen-independent state for the weather FX layer.
//
// Exactly one of these is instantiated (outside the per-screen Variants), so
// it owns the things that must not be duplicated: the config file watcher, the
// IPC handler, and the slow drift phases every monitor animates in lockstep.
//
// The JSON file at statePath is the single source of truth. `wallpaper-weather`
// edits it and then pokes reload() over IPC purely to skip the watcher's
// latency -- the watcher alone would still pick the change up.
Item {
  id: state
  visible: false

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/wallpaper-weather.json"

  // --- config -------------------------------------------------------------
  property bool fxEnabled: true
  property bool rain: false
  property bool day: false
  property bool night: false
  property bool thunder: false   // lightning; a storm, not plain rain
  property bool fog: false       // haze on the band the picture already has
  property real intensity: 1.0   // 0.2 .. 2.0, scales particle counts
  property real wind: 0.0        // -1 .. 1, rain slant
  property bool drift: true      // slow ken-burns push on the photo
  property bool parallax: true   // photo leans away from the pointer
  property bool grain: true
  property bool powerSave: true  // stand still while the desktop is covered

  // Persistent automatic modes. The CLI owns what each one sets; this just
  // asks it to tick.
  property bool followSun: false
  property bool followWeather: false

  // --- sky placement ------------------------------------------------------
  // Fractions of the panel rather than pixels, so the weather composes onto
  // whatever photograph is set instead of only the Osaka Jade city it was
  // drawn for. Defaults are that city; `wallpaper-weather sky` retunes them.
  //
  //   sun/moon X,Y   centre of the disc
  //   sun/moon Size  diameter, as a fraction of panel height
  //   horizon        where sky meets land: stars stop here, far mist sits on it
  //   skyLeft        stars fade in from this x, past any foreground obstruction
  //   groundLevel    top of the near foreground: fireflies and near mist start here
  property real sunX: 0.60
  property real sunY: 0.14
  property real sunSize: 0.95
  property real moonX: 0.60
  property real moonY: 0.11
  property real moonSize: 0.52
  property real horizon: 0.34
  property real skyLeft: 0.16
  property real groundLevel: 0.42
  // Where the far haze actually sits, measured rather than guessed from the
  // horizon -- the two are only the same on a picture with no depth to it.
  property real mistY: 0.30
  property real mistHeight: 0.34
  // Sampled from the picture, so the haze is the scene seen through lit air
  // rather than white smoke laid over it.
  property color hazeColor: "#9aa8a4"

  property bool bootstrapped: false

  // --- derived ------------------------------------------------------------
  readonly property bool rainOn: fxEnabled && rain
  readonly property bool dayOn: fxEnabled && day
  readonly property bool nightOn: fxEnabled && night
  // Thunder is a modifier on rain, not a mood of its own -- no rain, no storm.
  readonly property bool thunderOn: fxEnabled && rain && thunder
  readonly property bool fogOn: fxEnabled && fog
  readonly property int moodCount: (rainOn ? 1 : 0) + (dayOn ? 1 : 0) + (nightOn ? 1 : 0)
  readonly property bool anyMood: moodCount > 0
  readonly property real amount: Math.max(0.2, Math.min(2.0, intensity))

  // Colour grade applied to the photograph itself. Each mood contributes one
  // share and the active moods are averaged, so Rain+Day lands on "overcast
  // afternoon" instead of fighting each other, and Rain+Night on "storm".
  property real gradeBrightness: !anyMood ? 0 :
    ((rainOn ? -0.12 : 0) + (dayOn ? 0.26 : 0) + (nightOn ? -0.06 : 0)) / moodCount
  property real gradeContrast: !anyMood ? 0 :
    ((rainOn ? 0.04 : 0) + (dayOn ? -0.04 : 0) + (nightOn ? 0.10 : 0)) / moodCount
  property real gradeSaturation: !anyMood ? 0 :
    ((rainOn ? -0.34 : 0) + (dayOn ? 0.12 : 0) + (nightOn ? -0.08 : 0)) / moodCount
  property real gradeColorization: !anyMood ? 0 :
    ((rainOn ? 0.20 : 0) + (dayOn ? 0.30 : 0) + (nightOn ? 0.22 : 0)) / moodCount

  readonly property color gradeColorTarget: {
    if (moodCount === 0) return Qt.rgba(0, 0, 0, 1)
    var r = 0, g = 0, b = 0
    if (rainOn) { r += 0.086; g += 0.196; b += 0.239 }  // wet slate cyan
    if (dayOn) { r += 1.000; g += 0.843; b += 0.604 }   // low warm gold
    if (nightOn) { r += 0.043; g += 0.106; b += 0.200 } // deep indigo
    return Qt.rgba(r / moodCount, g / moodCount, b / moodCount, 1)
  }
  property color gradeColor: gradeColorTarget

  Behavior on gradeBrightness { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
  Behavior on gradeContrast { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
  Behavior on gradeSaturation { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
  Behavior on gradeColorization { NumberAnimation { duration: 900; easing.type: Easing.InOutCubic } }
  Behavior on gradeColor { ColorAnimation { duration: 900; easing.type: Easing.InOutCubic } }

  // Held out of gradeBrightness so its slow oscillation doesn't restart the
  // 900ms mood transition on every frame. Sampled off the slow clock: it
  // travels 0.028 of brightness in 9.3s, which is a 1/255 step every 1.3s --
  // there is nothing for a 60Hz frame to show that a 160ms one doesn't.
  readonly property real breathe:
    anyMood ? 0.004 + 0.014 * Math.sin(slowClock * 0.6756) : 0
  readonly property real fxBrightness: gradeBrightness + breathe

  // Stays true while the 900ms grade animation unwinds after the last mood is
  // switched off, so the offscreen layer is torn down at identity rather than
  // mid-fade (which would land as a visible snap).
  readonly property bool grading: anyMood
    || Math.abs(gradeBrightness) > 0.002
    || Math.abs(gradeContrast) > 0.002
    || Math.abs(gradeSaturation) > 0.002
    || gradeColorization > 0.002

  // --- the slow clock -----------------------------------------------------
  // Everything here moves at the speed of weather, not of a frame. The drift
  // crosses 61px in 112s -- 0.009px per frame at 60Hz -- so animating it with
  // a NumberAnimation marked the whole wallpaper dirty sixty times a second to
  // move it by a hundredth of a pixel, and cost ~22% CPU in the shell plus
  // ~11% in the compositor to do it. One shared 100ms tick drives all of it
  // instead, at a step of ~0.06px: below what a pixel can show, and a sixth of
  // the wakeups.
  //
  // The clock is elapsed seconds, read from the wall clock rather than
  // accumulated, so pausing and resuming it never puts a seam in the motion.
  readonly property int slowTickMs: 100
  property real slowEpoch: Date.now() / 1000
  property real slowClock: 0
  readonly property bool slowClockNeeded:
    fxEnabled && (drifting || anyMood || grading || grain) && desktopVisible

  // --- is anyone looking? -------------------------------------------------
  // An animated wallpaper costs the same whether or not there is a window in
  // front of it: the surface is redrawn and the compositor recomposites it
  // either way. So ask Hyprland what is on each monitor's active workspace and
  // stand still while every one of them is covered -- which, on a machine
  // being worked on, is most of the day.
  //
  // Read off workspaces rather than monitors: Hyprland.monitors populates
  // without its activeWorkspace links attached, so a monitor-first version of
  // this test silently answered "visible" forever. Each workspace knows both
  // whether it is the active one on its monitor and what is on it.
  //
  // Anything unknown counts as visible. A wrong "nobody is looking" freezes
  // the wallpaper in someone's face; a wrong "someone is looking" only costs
  // what the plugin used to cost anyway.
  function anyBareDesktop(workspaces) {
    var sawActive = false
    for (var i = 0; i < workspaces.length; ++i) {
      var w = workspaces[i]
      if (!w || !w.active) continue
      sawActive = true
      if (!w.toplevels || w.toplevels.values.length === 0) return true
    }
    return !sawActive
  }

  readonly property bool desktopVisible:
    !powerSave || anyBareDesktop(Hyprland.workspaces.values)

  // The models are lazily populated, and nothing else here would ask.
  Component.onCompleted: {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
  }

  Timer {
    interval: state.slowTickMs
    repeat: true
    running: state.slowClockNeeded
    triggeredOnStart: true
    onTriggered: state.slowClock = Date.now() / 1000 - state.slowEpoch
  }

  // --- drift --------------------------------------------------------------
  // Three incommensurable periods so the framing never visibly repeats.
  readonly property bool drifting: fxEnabled && drift
  readonly property real driftX: drifting ? Math.sin(slowClock * 0.0280500) : 0
  readonly property real driftY: drifting ? 0.7 * Math.sin(slowClock * 0.0361111 + 1.3) : 0
  readonly property real driftZoom: drifting ? 0.5 + 0.5 * Math.sin(slowClock * 0.0219690 + 2.1) : 0


  // --- automatic modes ----------------------------------------------------
  readonly property string cliPath:
    Qt.resolvedUrl("bin/wallpaper-weather").toString().replace(/^file:\/\//, "")

  Process {
    id: tickProc
    command: [state.cliPath, "tick"]
  }

  // Sky placement belongs to the picture, so a wallpaper change has to bring
  // its own composition with it -- otherwise the moon stays where the last
  // wallpaper's sky was. `sky recall` restores a saved placement, or measures
  // the image the first time it sees it.
  Process {
    id: recallProc
    command: [state.cliPath, "sky", "recall"]
  }

  Process {
    id: bgWatchProc
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (!path || path === state.lastBackground) return
        var first = state.lastBackground === ""
        state.lastBackground = path
        // Don't re-measure on startup: whatever is in the state file is
        // already what the user last saw.
        if (!first && !recallProc.running) recallProc.running = true
      }
    }
  }

  property string lastBackground: ""

  Timer {
    interval: 4000
    repeat: true
    running: state.fxEnabled
    triggeredOnStart: true
    onTriggered: if (!bgWatchProc.running) bgWatchProc.running = true
  }

  function tick() {
    if (!tickProc.running) tickProc.running = true
  }

  Timer {
    id: modeTimer
    // Five minutes is finer than sunrise needs and coarser than wttr's own
    // 15-minute cache, so `tick` mostly costs a date comparison.
    interval: 5 * 60 * 1000
    repeat: true
    running: state.fxEnabled && (state.followSun || state.followWeather)
    triggeredOnStart: true
    onTriggered: state.tick()
  }

  // --- persistence --------------------------------------------------------
  function bool_(value, fallback) {
    if (value === undefined || value === null) return fallback
    return value === true || value === "true" || value === 1
  }

  function num_(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  // Placement values are panel fractions; anything outside 0..1 would put the
  // effect off screen, and a NaN here would reach the scene graph as corrupt
  // geometry rather than as a visible mistake.
  function frac_(value, fallback) {
    return Math.max(0, Math.min(1, num_(value, fallback)))
  }

  function applyJson(raw) {
    var cfg = {}
    try {
      cfg = JSON.parse(String(raw || "{}")) || {}
    } catch (error) {
      console.warn("weather-fx: unreadable config, keeping current state:", error)
      return
    }
    fxEnabled = bool_(cfg.enabled, true)
    rain = bool_(cfg.rain, false)
    day = bool_(cfg.day, false)
    night = bool_(cfg.night, false)
    thunder = bool_(cfg.thunder, false)
    fog = bool_(cfg.fog, false)
    drift = bool_(cfg.drift, true)
    parallax = bool_(cfg.parallax, true)
    grain = bool_(cfg.grain, true)
    powerSave = bool_(cfg.powerSave, true)
    followSun = bool_(cfg.followSun, false)
    followWeather = bool_(cfg.followWeather, false)
    intensity = num_(cfg.intensity, 1.0)
    wind = Math.max(-1, Math.min(1, num_(cfg.wind, 0.0)))

    var sky = (cfg.sky && typeof cfg.sky === "object") ? cfg.sky : {}
    sunX = frac_(sky.sunX, 0.60); sunY = frac_(sky.sunY, 0.14)
    moonX = frac_(sky.moonX, 0.60); moonY = frac_(sky.moonY, 0.11)
    sunSize = Math.max(0.05, num_(sky.sunSize, 0.95))
    moonSize = Math.max(0.05, num_(sky.moonSize, 0.52))
    horizon = frac_(sky.horizon, 0.34)
    skyLeft = frac_(sky.skyLeft, 0.16)
    groundLevel = frac_(sky.groundLevel, 0.42)
    mistY = frac_(sky.mistY, 0.30)
    mistHeight = Math.max(0.06, num_(sky.mistHeight, 0.34))
    hazeColor = String(sky.hazeColor || "#9aa8a4")

    bootstrapped = true
  }

  function defaultsJson() {
    return JSON.stringify({
      enabled: true, rain: false, day: false, night: true, thunder: false, fog: false,
      intensity: 1.0, wind: 0.0, drift: true, parallax: true, grain: true,
      powerSave: true,
      followSun: false, followWeather: false,
      sky: {
        sunX: 0.60, sunY: 0.14, sunSize: 0.95,
        moonX: 0.60, moonY: 0.11, moonSize: 0.52,
        horizon: 0.34, skyLeft: 0.16, groundLevel: 0.42,
        mistY: 0.30, mistHeight: 0.34, hazeColor: "#9aa8a4"
      }
    }, null, 2) + "\n"
  }

  FileView {
    id: configFile
    path: state.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: state.applyJson(text())
    onFileChanged: reload()
    onLoadFailed: {
      // First run, or the file was removed under us. Seed it once; the write
      // comes back around through onFileChanged and settles.
      if (state.bootstrapped) return
      state.bootstrapped = true
      state.applyJson(state.defaultsJson())
      setText(state.defaultsJson())
    }
  }

  IpcHandler {
    target: "wallpaper-weather"

    // Nudge the watcher instead of waiting on it. `wallpaper-weather` has already
    // written the file by the time this lands.
    function reload(): void {
      configFile.reload()
    }

    function status(): string {
      return JSON.stringify({
        enabled: state.fxEnabled, rain: state.rain, day: state.day, night: state.night,
        thunder: state.thunder, fog: state.fog,
        intensity: state.intensity, wind: state.wind,
        drift: state.drift, parallax: state.parallax, grain: state.grain,
        powerSave: state.powerSave, desktopVisible: state.desktopVisible
      })
    }
  }
}
