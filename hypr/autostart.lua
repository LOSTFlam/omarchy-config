-- Extra autostart processes.
-- o.launch_on_start("my-service")

-- Lid sounds: evdev monitor daemon (IdeaPad Gaming 3 doesn't trigger
-- Hyprland's Lid Switch binds, so this runs outside Hyprland).
o.exec_on_start("~/.venvs/evdev/bin/python ~/.local/bin/lid-monitor-evdev.py")

-- Persistent cursor theme — runs on every Hyprland start, after the env vars
-- in looknfeel.lua are set, so the cursor theme survives reboots even if a
-- theme switch resets it mid-session.
hl.on("hyprland.start", function()
  hl.exec_cmd("hyprctl setcursor oreo_black_cursors 24")
end)