-- Extra autostart processes.
-- o.launch_on_start("my-service")
o.exec_on_start("~/.venvs/evdev/bin/python ~/.local/bin/lid-monitor-evdev.py")
