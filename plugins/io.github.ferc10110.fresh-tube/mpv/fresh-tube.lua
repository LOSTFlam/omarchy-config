-- Fresh Tube's mpv companion. Loaded by `fresh-tube play` with
--   --script-opt=fresh_tube-id=<videoId> --script-opt=fresh_tube-bin=<path to bin/fresh-tube>
--   [--script-opt=fresh_tube-fallback=<player to use when the video cannot be opened>]
-- It tells the plugin when the video reaches its end (so the video leaves the
-- Watch later list), remembers the window size when mpv closes, and hands the
-- video to the fallback player when mpv could not open it at all.
local mp = require("mp")

local video_id = mp.get_opt("fresh_tube-id")
local bin = mp.get_opt("fresh_tube-bin")
local fallback = mp.get_opt("fresh_tube-fallback")
if not video_id or video_id == "" or not bin or bin == "" then
  return
end

local loaded = false
local done_sent = false
local fallback_sent = false
local last_w, last_h = 0, 0

-- Fire and forget: detached, and never tied to the playback lifetime, so a
-- call made while mpv is shutting down still runs.
local function run(args)
  mp.command_native({
    name = "subprocess",
    args = args,
    detach = true,
    playback_only = false,
  })
end

local function mark_done()
  if done_sent then
    return
  end
  done_sent = true
  run({ bin, "done", "--", video_id })
end

local function open_fallback()
  if fallback_sent or not fallback or fallback == "" then
    return
  end
  fallback_sent = true
  run({ bin, "play", "--player", fallback, "--", video_id })
end

mp.register_event("file-loaded", function()
  loaded = true
end)

mp.register_event("end-file", function(event)
  if event.reason == "eof" then
    mark_done()
  elseif event.reason == "error" and not loaded then
    -- mpv could not open the video at all (yt-dlp refused, private video...):
    -- a browser with the user's session usually can.
    open_fallback()
  end
end)

-- With keep-open=yes in the user's mpv.conf, mpv pauses at the end instead of
-- unloading the file; eof-reached covers that.
mp.observe_property("eof-reached", "bool", function(_, reached)
  if reached then
    mark_done()
  end
end)

-- Only sizes of a window that shows a video count: the black window of a
-- video that never loaded is not the size the user chose. A fullscreen window
-- reports the monitor's size, not the size the user chose.
mp.observe_property("osd-dimensions", "native", function(_, dims)
  if loaded and not mp.get_property_native("fullscreen") and dims and dims.w and dims.h and dims.w > 0 and dims.h > 0 then
    last_w, last_h = math.floor(dims.w), math.floor(dims.h)
  end
end)

mp.register_event("shutdown", function()
  if last_w > 0 and last_h > 0 then
    run({ bin, "prefs", "set", "playerWidth", tostring(last_w), "playerHeight", tostring(last_h) })
  end
end)
