.pragma library

function xdg(value, home, fallback) {
  return String(value || "").charAt(0) === "/" ? String(value) : String(home || "") + "/" + fallback
}

function cachePrefix(path) {
  if (String(path || "").charAt(0) !== "/") return ""
  return "file://" + String(path).split("/").map(function(part) {
    return encodeURIComponent(part).replace(/[!'()*]/g, function(char) {
      return "%" + char.charCodeAt(0).toString(16).toUpperCase()
    })
  }).join("/") + "/"
}

function trustedFile(value, root, pattern) {
  var prefix = cachePrefix(root)
  var url = String(value || "")
  return Boolean(prefix) && url.indexOf(prefix) === 0 && pattern.test(url.slice(prefix.length))
}
