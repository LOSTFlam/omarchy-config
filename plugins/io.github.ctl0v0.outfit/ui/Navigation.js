.pragma library

function contains(parent, item) {
    for (var current = item; current; current = current.parent)
        if (current === parent) return true
    return false
}

// Detect the actual editor, including the editor inside a styled text control.
// Read-only selectable text also owns its caret and selection keys.
function textEditing(item) {
    for (var current = item; current; current = current.parent)
        if (current.cursorPosition !== undefined && current.text !== undefined
                && typeof current.selectAll === "function") return true
    return false
}

function focusableChildren(item) {
    var result = []
    for (var child of item.children || []) {
        if (!child.visible || !child.enabled) continue
        if (child.activeFocusOnTab) result.push(child)
        else result = result.concat(focusableChildren(child))
    }
    return result
}

// Geometry, rather than a guessed column count, handles variable card heights,
// density reflows and the short final row of each category group.
function adjacent(rects, index, key) {
    if (index < 0 || index >= rects.length) return index
    var from = rects[index], best = index, nearest = Infinity, nearestCross = Infinity
    var vertical = key === Qt.Key_Up || key === Qt.Key_Down
    var sign = key === Qt.Key_Up || key === Qt.Key_Left ? -1 : 1
    for (var i = 0; i < rects.length; i++) {
        if (i === index) continue
        var candidate = rects[i]
        var dx = candidate.x - from.x, dy = candidate.y - from.y
        var primary = (vertical ? dy : dx) * sign
        var cross = Math.abs(vertical ? dx : dy)
        if (primary <= 1) continue
        // Horizontal movement stays in the visual row.
        if (!vertical && cross > Math.min(from.height, candidate.height) / 2) continue
        if (primary < nearest - 1 || (Math.abs(primary - nearest) <= 1 && cross < nearestCross)) {
            nearest = primary
            nearestCross = cross
            best = i
        }
    }
    return best
}
