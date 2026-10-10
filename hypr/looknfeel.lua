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
      range = 50,
      render_power = 1,
    },
  },

  dwindle = {
    smart_split = true,
  },
})

hl.animation({ leaf = "global", enabled = true, speed = 40, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 21.56, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 15.16, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 16.4, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 5.96, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 6.92, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 5.84, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 12.12, bezier = "quick" })
hl.animation({ leaf = "fadeSwitch", enabled = false })
hl.animation({ leaf = "layers", enabled = true, speed = 15.24, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 16, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 6, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 7.16, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 5.56, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = false })
-- <<< omaland managed block <<<

hl.curve("easeOutBack", { type = "bezier", points = { { 0.34, 1.3 }, { 0.64, 1 } } })
hl.curve("bouncy", { type = "spring", mass = 1, stiffness = 240, dampening = 22 })

local function active_border_gradient()
  local current = hl.get_config("general:col.active_border")
  local first = current
  if type(current) == "table" then
    first = current.colors and current.colors[1]
  end

  local r, g, b, a
  if type(first) == "number" then
    a = math.floor(first / 16777216) % 256
    r = math.floor(first / 65536) % 256
    g = math.floor(first / 256) % 256
    b = first % 256
  elseif type(first) == "string" then
    local hex = first:match("0[xX](%x+)")
    if hex then
      if #hex == 6 then
        hex = "ff" .. hex
      end
      if #hex == 8 then
        a = tonumber(hex:sub(1, 2), 16)
        r = tonumber(hex:sub(3, 4), 16)
        g = tonumber(hex:sub(5, 6), 16)
        b = tonumber(hex:sub(7, 8), 16)
      end
    else
      hex = first:match("#(%x+)") or first:match("rgba?%((%x+)%)")
      if hex and #hex >= 6 then
        if #hex == 6 then
          hex = "ff" .. hex
        end
        r = tonumber(hex:sub(1, 2), 16)
        g = tonumber(hex:sub(3, 4), 16)
        b = tonumber(hex:sub(5, 6), 16)
        a = tonumber(hex:sub(7, 8), 16)
      end
    end
  end

  if not r or not a then
    return nil
  end

  local function mix(c)
    return math.floor(c + (255 - c) * 0.5 + 0.5)
  end

  local function rgba(rr, gg, bb, aa)
    return string.format("rgba(%02x%02x%02x%02x)", rr, gg, bb, aa)
  end

  return {
    colors = { rgba(r, g, b, a), rgba(mix(r), mix(g), mix(b), a) },
    angle = 135,
  }
end

local gradient = active_border_gradient()

hl.config({
  general = {
    resize_on_border = true,
    allow_tearing = true,
    col = gradient and { active_border = gradient } or nil,
  },

  group = gradient and { col = { border_active = gradient } } or nil,

  decoration = {
    motion_blur = {
      enabled = true,
      samples = 10,
    },
  },

  misc = {
    animate_manual_resizes = true,
    animate_mouse_windowdragging = true,
  },

  cursor = {
    inactive_timeout = 5,
  },
})

hl.animation({ leaf = "windowsMove", enabled = true, speed = 1, bezier = "quick" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 2.5, bezier = "easeInOutCubic" })
hl.animation({ leaf = "fadeShadow", enabled = true, speed = 2, bezier = "quick" })
hl.animation({ leaf = "fadePopupsIn", enabled = true, speed = 2, bezier = "quick" })
hl.animation({ leaf = "fadePopupsOut", enabled = true, speed = 1.6, bezier = "almostLinear" })
hl.animation({ leaf = "fadeDpms", enabled = true, speed = 8, bezier = "easeOutQuint" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 3, spring = "bouncy" })
hl.animation({ leaf = "monitorAdded", enabled = true, speed = 5, bezier = "quick" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 3.5, bezier = "easeOutBack", style = "slidefade 20%" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 3.5, bezier = "easeOutBack", style = "slidefade 20%" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 60, bezier = "linear", style = "loop" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3.5, bezier = "easeOutBack", style = "slidefadevert 20%" })
hl.animation({ leaf = "specialWorkspaceIn", enabled = true, speed = 3.5, bezier = "easeOutBack", style = "slidefadevert 20%" })
hl.animation({ leaf = "specialWorkspaceOut", enabled = true, speed = 3.5, bezier = "easeOutBack", style = "slidefadevert 20%" })

hl.window_rule({
  name = "fx-video-idle",
  match = { content = "video" },
  idle_inhibit = "fullscreen",
  opaque = true,
})

hl.window_rule({
  name = "fx-game-tearing",
  match = { content = "game" },
  immediate = true,
  opaque = true,
  nearest_neighbor = true,
})

hl.window_rule({
  name = "fx-media-idle",
  match = { class = "^(mpv|celluloid|vlc|haruna|smplayer)$" },
  content = "video",
  idle_inhibit = "focus",
  opaque = true,
})

hl.window_rule({
  name = "fx-modal",
  match = { modal = true },
  center = true,
  dim_around = true,
  animation = "popin 80%",
})

hl.layer_rule({
  match = { namespace = "^(omarchy-bar|omarchy-rice-bar)$" },
  no_anim = false,
  animation = "slide top",
  blur = true,
  blur_popups = true,
  ignore_alpha = 0.5,
})

hl.layer_rule({
  match = { namespace = "^(omarchy-dock|omarchy-dock-edge)$" },
  no_anim = false,
  animation = "slide bottom",
  blur = true,
  blur_popups = true,
  ignore_alpha = 0.5,
})

hl.layer_rule({
  match = { namespace = "^(omarchy-menu|omarchy-clipboard|omarchy-emojis|omarchy-image-selector|omarchy-keyboard-panel|omarchy-reminders)$" },
  no_anim = false,
  animation = "popin 90%",
  blur = true,
  blur_popups = true,
  ignore_alpha = 0.5,
})

hl.layer_rule({
  match = { namespace = "omarchy-osd" },
  no_anim = false,
  animation = "popin 85%",
  blur = true,
  ignore_alpha = 0.4,
})

hl.layer_rule({
  match = { namespace = "selection" },
  no_anim = false,
  animation = "fade",
})

hl.layer_rule({
  match = { namespace = "^(omarchy-speed-test|omarchy-disk-speedtest|omarchy-network-speedtest)$" },
  no_anim = false,
  animation = "popin 90%",
  blur = true,
  ignore_alpha = 0.5,
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "vertical", action = "special", workspace_name = "scratchpad" })
hl.gesture({ fingers = 3, direction = "down", mods = "ALT", action = "close" })
hl.gesture({ fingers = 3, direction = "up", mods = "ALT", action = "fullscreen" })
hl.gesture({ fingers = 2, direction = "pinch", action = "cursor_zoom", mode = "live" })

-- Opt another application in to Omarchy's standard transparency.
-- Find its class with: hyprctl clients
-- o.transparent_window("my-app")
-- o.transparent_window("my-app", "0.9 0.85") -- Custom active/inactive opacity.
