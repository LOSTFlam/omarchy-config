-- Change the default Omarchy look'n'feel.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
-- hl.config({
--   general = {
--     -- No gaps between windows or borders.
--     gaps_in = 0,
--     gaps_out = 0,
--     border_size = 0,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
-- hl.config({
--   decoration = {
--     -- Use round window corners.
--     rounding = 8,
--
--     -- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
--     dim_inactive = true,
--     dim_strength = 0.15,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })

-- >>> omaland managed block >>>
-- Written by Omaland. Safe to hand-edit: Omaland re-reads this block
-- every time it opens, and only ever rewrites what's between the fences.
hl.config({
  decoration = {
    active_opacity = 0.8,
    dim_inactive = true,
    inactive_opacity = 0.5,

    glow = {
      enabled = false,
      render_power = 1,
    },
  },
})

hl.animation({ leaf = "global", enabled = true, speed = 20, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 10.78, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 7.58, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 8.2, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.98, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 3.46, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 2.92, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 6.06, bezier = "quick" })
hl.animation({ leaf = "fadeSwitch", enabled = false })
hl.animation({ leaf = "layers", enabled = true, speed = 7.62, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 8, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 3, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 3.58, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 2.78, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = false })
-- <<< omaland managed block <<<
