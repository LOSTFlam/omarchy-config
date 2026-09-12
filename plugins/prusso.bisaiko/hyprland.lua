-- Bisaikō: float its 80x24 terminal at the position selected in its menu.
local bisaiko_windows = {
  ["top-left"] = { "8", "26" },
  ["top-center"] = { "(monitor_w-window_w)/2", "26" },
  ["top-right"] = { "monitor_w-window_w-8", "26" },
  ["middle-left"] = { "8", "(monitor_h-window_h)/2" },
  ["center"] = { "(monitor_w-window_w)/2", "(monitor_h-window_h)/2" },
  ["middle-right"] = { "monitor_w-window_w-8", "(monitor_h-window_h)/2" },
  ["bottom-left"] = { "8", "monitor_h-window_h-8" },
  ["bottom-center"] = { "(monitor_w-window_w)/2", "monitor_h-window_h-8" },
  ["bottom-right"] = { "monitor_w-window_w-8", "monitor_h-window_h-8" },
}

for position, coordinates in pairs(bisaiko_windows) do
  o.window("^org\\.omarchy\\.bisaiko\\." .. position .. "$", {
    float = true,
    move = coordinates,
    animation = "slide top",
  })
end
