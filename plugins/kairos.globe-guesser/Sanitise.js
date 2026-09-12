.pragma library

// Sanitising for text that crosses out of this plugin, and for text that
// crosses into it.
//
// Every Text element the plugin owns sets textFormat: Text.PlainText. That is
// necessary and not sufficient, because two of the sinks a bar widget writes to
// are not the plugin's to configure:
//
//   /usr/share/omarchy/shell/Ui/WidgetButton.qml   the bar label
//   /usr/share/omarchy/shell/plugins/bar/Bar.qml   the bar tooltip
//
// Neither sets textFormat anywhere -- in fact exactly one textFormat assignment
// exists in the whole shell, in the notifications plugin -- so both fall back to
// Qt's default Text.AutoText, which sniffs its input and renders it as HTML,
// including <img src="http://..."> , which performs a network fetch from inside
// the shared shell process. Crossing that boundary is what a bar widget does, so
// it cannot be avoided; the string has to be safe before it goes.
//
// This plugin has a second reason to care. Wikimedia Commons returns the
// photographer credit as literal HTML -- a measured value was
//
//   <a href="//commons.wikimedia.org/wiki/User:Cedricbonhomme" ...>Cedric</a>
//
// so the attribution line is markup by design, not by attack, and stripping it
// is part of displaying it correctly rather than a defensive extra.
//
// This lives in its own file so it can be tested directly, under both node and
// Qt's V4 engine, against the payloads marketplace reviewers actually use.
// See tools/check-geomath.js and tools/check-qml-engine.qml.

// Collapses an untrusted string to a single safe line.
//
// Three removals, each for its own reason:
//
//   < >    no tag can survive without them
//   &      removing only the brackets still leaves &#60; and &lt;, which the
//          rich-text engine decodes back into a bracket. Taking the ampersand
//          closes the only route back.
//   ctrl   control characters and newlines, which let one value forge what
//          looks like a second line of the display
//
// Then whitespace is collapsed and the result length-capped, because a Commons
// credit can run to several hundred characters of nested markup and would paint
// a tooltip across the whole screen.
function plainOneLine(value, maxLength) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\x00-\x1f\x7f]/g, " ")
  text = text.replace(/[<>&]/g, "")
  text = text.replace(/\s+/g, " ")
  text = text.replace(/^\s+|\s+$/g, "")
  var limit = maxLength > 0 ? maxLength : 160
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}

// For a value that is HTML by design: the Commons Artist field. Tags are
// unwrapped to their text content rather than deleted outright, so
// `<a href="...">Cedric Bonhomme</a>` reads as "Cedric Bonhomme" and not as
// nothing at all, and the entities Commons emits are decoded to the characters
// they stand for before plainOneLine removes what is left.
//
// Order matters and is the opposite of what looks natural: tags are stripped
// FIRST, then entities decoded, then plainOneLine runs. Decoding before
// stripping would turn &lt;img src=x&gt; into a live tag; plainOneLine last is
// what guarantees a bracket produced by decoding still cannot survive.
function creditText(value, maxLength) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/<[^>]*>/g, " ")
  text = text.replace(/&nbsp;/gi, " ")
  text = text.replace(/&amp;/gi, "&")
  text = text.replace(/&quot;/gi, '"')
  text = text.replace(/&#0*39;|&apos;/gi, "'")
  text = text.replace(/&lt;/gi, "<")
  text = text.replace(/&gt;/gi, ">")
  return plainOneLine(text, maxLength > 0 ? maxLength : 120)
}

// A Commons file title, with the "File:" prefix and the extension removed and
// underscores turned back into spaces, then sanitised. Accented and hyphenated
// names have to survive this -- "Quebec", "Marrakesh", "D-AIGW" are real data,
// and a whitelist narrow enough to be safe would destroy them -- so the
// characters stay and only the markup-significant ones go.
function titleText(value, maxLength) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/^File:/i, "")
  text = text.replace(/\.(jpe?g|png|gif|tiff?|webp)$/i, "")
  text = text.replace(/_/g, " ")
  return plainOneLine(text, maxLength > 0 ? maxLength : 90)
}

// A short identifier that a whitelist can safely bound: the licence
// short-name. "CC BY-SA 4.0", "CC0", "Public domain" are the whole universe of
// real values, so anything outside that alphabet is dropped rather than
// escaped.
function licenceText(value) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[^A-Za-z0-9 .+-]/g, "")
  text = text.replace(/\s+/g, " ")
  text = text.replace(/^\s+|\s+$/g, "")
  return text.length > 40 ? text.substring(0, 40) : text
}


// A local file path on its way to Image.source, or "" if it is not one.
//
// `source:` is a URL sink that resolves whatever it is given: `file://`,
// `image://` and a bare absolute path all fetch, and `image://` reaches QML image
// providers inside the shell. Panel.qml already checks that a photo path came out
// of its own download script and sits inside the private cache directory; this is
// the second check, at the sink, because a sink should not depend on a caller
// elsewhere in the repo continuing to be careful.
//
// Absolute, no scheme of its own, no traversal, no control characters, and a
// length no real path has. Anything else is "", and an Image with an empty source
// fetches nothing.
function localFileUrl(value) {
  var path = String(value === undefined || value === null ? "" : value)
  if (path === "" || path.length > 4096) return ""
  if (path.charAt(0) !== "/") return ""
  if (path.indexOf("://") >= 0) return ""
  if (path.indexOf("..") >= 0) return ""
  if (/[\u0000-\u001f\u007f]/.test(path)) return ""
  return "file://" + path
}
