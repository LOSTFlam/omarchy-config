import QtQuick
import QtQuick.Effects
import qs.Commons
import "Sanitise.js" as Sanitise

// The photo half of the board.
//
// The source is always a local file that Panel.qml has already downloaded and
// checked. It is never a network URL: the address comes out of an API response,
// so it is attacker-influenced, and pointing Image.source at it would hand a
// remote server an unbounded fetch and decode inside the long-lived shell
// process. By the time a path reaches this file it has been through a host
// allowlist, a byte ceiling, a magic-number check, and -- for PNG, where Qt
// would otherwise decode the whole source before sourceSize could reduce it --
// a check on the dimensions its header declares.
//
// The photograph is shown WHOLE. An earlier revision filled the pane with
// PreserveAspectCrop, which is the right choice for a decorative background and
// the wrong one for a puzzle: it quietly cut the top and bottom off every
// landscape shot, and the horizon, the skyline and the hills above it are
// exactly the parts you guess from. Fitting instead leaves gaps, and the gaps
// are filled with a blurred, dimmed copy of the same photograph so the pane
// still reads as one image rather than as a picture floating on a slab.
Item {
  id: root

  // Absolute path to the downloaded file, or "" for none.
  property string photoPath: ""

  property bool loading: false
  property string errorText: ""

  // Shown only after the guess is locked in: naming the place while the player
  // is still guessing would give the answer away.
  property bool showAttribution: false
  property string photoTitle: ""
  property string photoCredit: ""
  property string photoLicence: ""

  property color foreground: Color.popups.text
  property color background: Color.popups.background

  readonly property bool ready: image.status === Image.Ready

  // Built through Sanitise.localFileUrl rather than concatenated here, so the
  // guard on this sink is covered by the check suites like every other boundary
  // function. See that function for what it refuses and why.
  readonly property url photoSource: Sanitise.localFileUrl(root.photoPath)

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    radius: Style.cornerRadius
    clip: true

    // ------------------------------------------------------------- backdrop
    //
    // The same file again, cropped to fill, then blurred and dimmed. Decoded at
    // 160px wide rather than at pane size: it is about to be blurred into a
    // wash, so decoding it any larger would spend memory and a decode on detail
    // that is deliberately destroyed. It never draws directly -- MultiEffect
    // reads it as a texture, which is why it is visible: false.
    //
    // Note that this is a SECOND decode of the same file, so whatever a source
    // costs to decode is paid twice over. One more reason the real ceiling has
    // to be the header check in Panel.qml rather than anything set here.
    Image {
      id: backdrop
      anchors.fill: parent
      source: root.photoSource
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: 160
      visible: false
    }

    MultiEffect {
      anchors.fill: parent
      source: backdrop
      visible: backdrop.status === Image.Ready
      blurEnabled: true
      blur: 1.0
      blurMax: 48
      // Pushed down and desaturated so it stays a backdrop. At full brightness
      // the blurred copy competes with the photograph in front of it and the eye
      // keeps being pulled to the edges of the pane; pushed too far the other
      // way -- -0.45 was -- it stops reading as a blur at all and the pane looks
      // like a small picture in a black box.
      brightness: -0.22
      saturation: -0.25
    }

    // ---------------------------------------------------------- the photo
    Image {
      id: image
      anchors.fill: parent
      source: root.photoSource

      // Fit, not crop. Nothing about the photograph is hidden from the player.
      fillMode: Image.PreserveAspectFit
      asynchronous: true

      // Qt's pixmap cache keys on URL, and a round's file is written once and
      // never revisited, so caching it would only hold bytes the game is
      // finished with.
      cache: false

      // The size of the PIXMAP THAT IS KEPT is decided here, not by the file.
      // Rounded up to a coarse step so a resize by a few pixels does not force a
      // re-decode.
      //
      // This is the second bound on the decode rather than the only one, and it
      // is worth being exact about which half of it this does. Qt scales during
      // load for JPEG only. For a PNG it loads the source at its full declared
      // size and scales afterwards, so sourceSize bounds what is RETAINED and
      // not what is ALLOCATED on the way there -- measured, an 8000x8000 PNG of
      // 61 KiB still peaked at 439.6 MiB with sourceSize set to 320x240.
      //
      // The bound that actually stops that is upstream, in Panel.qml: the
      // downloader reads the PNG header and refuses the file on its declared
      // dimensions before it is ever handed back as a path this pane can load.
      // See photoMaxPixels there for the measurements.
      sourceSize.width: Math.max(320, Math.ceil(root.width / 160) * 160)
      sourceSize.height: Math.max(240, Math.ceil(root.height / 160) * 160)

      visible: status === Image.Ready
    }

    // Loading.
    Text {
      anchors.centerIn: parent
      visible: root.loading && !image.visible && root.errorText === ""
      text: "Finding a photo…"
      textFormat: Text.PlainText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Failure, including a file that arrived but would not decode.
    Text {
      anchors.centerIn: parent
      anchors.margins: Style.space(16)
      width: parent.width - Style.space(32)
      visible: root.errorText !== "" || (root.photoPath !== "" && image.status === Image.Error)
      text: root.errorText !== "" ? root.errorText : "That photo would not load."
      textFormat: Text.PlainText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    // Attribution. These photographs are almost all CC-licensed, and the licence
    // is only honoured if the author and the terms travel with the picture, so
    // this is a requirement of using the images at all rather than a nicety.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: attributionColumn.implicitHeight + Style.space(16)
      visible: root.showAttribution && root.ready
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.82)

      Column {
        id: attributionColumn
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: root.photoTitle
          // Every Text in this plugin pins PlainText, not only the ones that
          // happen to carry remote data today, so the safe default also covers
          // whatever the next edit adds.
          textFormat: Text.PlainText
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            var parts = []
            if (root.photoCredit !== "") parts.push(root.photoCredit)
            if (root.photoLicence !== "") parts.push(root.photoLicence)
            return parts.join(" · ")
          }
          textFormat: Text.PlainText
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
