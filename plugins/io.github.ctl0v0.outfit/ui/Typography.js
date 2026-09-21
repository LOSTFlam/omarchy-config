.pragma library

// Consume the shell's resolved sizes (already scaled), never scale them twice.
// Call from root bindings so family/theme changes also update measured layouts.
function reading(font) { return Math.round(Math.max(font.body, font.bodySmall * 1.18)) }
function supporting(font) { return Math.max(font.body, font.caption) }
function value(font) { return Math.max(reading(font), font.heading || font.subtitle) }
function icon(font) { return Math.round(reading(font) * 18 / 13) }
function target(font) { return Math.round(reading(font) * 36 / 13) }
