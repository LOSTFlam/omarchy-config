.pragma library

// Build a tiny internal RichText vocabulary from data, never from README HTML.
// This second boundary also makes malformed/stale cache or fixture data inert.
function escape(value) {
    return String(value === undefined || value === null ? "" : value)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function safeUrl(value) {
    var url = String(value || "")
    if (url.length > 1200 || !/^https:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::443)?(?:[/?#]|$)/.test(url)) return ""
    try {
        if (/[\x00-\x20\x7f\\<>"']/.test(decodeURIComponent(url))) return ""
    } catch (e) { return "" }
    return url
}

function isList(value) {
    // Qt may bridge initial properties as QVariantList rather than JS Array.
    return value !== null && typeof value === "object" && typeof value.length === "number"
}

function rich(tokens, accent, depth, inLink) {
    depth = depth || 0
    if (!isList(tokens) || depth > 12) return ""
    var out = ""
    for (var i = 0; i < tokens.length; i++) {
        var token = tokens[i] || {}
        if (token.kind === "text") out += escape(token.text)
        else if (token.kind === "code") out += "<tt>" + escape(token.text) + "</tt>"
        else {
            var url = token.kind === "link" && !inLink ? safeUrl(token.url) : ""
            var body = rich(token.children, accent, depth + 1, inLink || Boolean(url))
            if (url) out += '<a href="' + escape(url) + '"><font color="' + escape(accent) + '">' + body + '</font></a>'
            else if (token.kind === "strong") out += "<b>" + body + "</b>"
            else if (token.kind === "em") out += "<i>" + body + "</i>"
            else if (token.kind === "strike") out += "<s>" + body + "</s>"
            else out += body
        }
    }
    return out
}
