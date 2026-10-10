#!/usr/bin/env python3
"""
Демон мониторинга крышки через evdev на /dev/input/event0 (Lid Switch)
Самый низкий уровень — читает SW_LID события прямо из ядра Linux.
IdeaPad Gaming 3: /proc/acpi/button/lid/LID/state НЕ обновляется,
Hyprland switch:on/off тоже не срабатывает, UPower тоже не видит.
Но evdev читает события ядра напрямую — должно работать.
"""

import subprocess
import time
from pathlib import Path
from datetime import datetime

import evdev
from evdev import ecodes

LID_DEVICE = "/dev/input/event0"
LOG_FILE = Path.home() / ".local/state/lid-sound.log"
HANDLER = str(Path.home() / ".local/bin/lid-sound-handler")


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}\n")


def play_sound(state: str) -> None:
    subprocess.Popen([HANDLER, state], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> None:
    log(f"evdev lid monitor started (device={LID_DEVICE})")

    # Ждём появления устройства
    while not Path(LID_DEVICE).exists():
        time.sleep(1)

    try:
        device = evdev.InputDevice(LID_DEVICE)
    except PermissionError:
        log("ERROR: нет прав на чтение устройства. Добавь себя в группу input:")
        log("  sudo usermod -aG input $USER && newgrp input")
        return

    log(f"connected to: {device.name}")

    prev_state = None

    try:
        # Запрашиваем текущее состояние через ioctl (если доступно)
        try:
            caps = device.capabilities()
            if ecodes.EV_SW in caps and ecodes.SW_LID in caps[ecodes.EV_SW]:
                log("SW_LID capability detected")
        except Exception:
            pass

        for event in device.read_loop():
            if event.type == ecodes.EV_SW and event.code == ecodes.SW_LID:
                state = "close" if event.value == 1 else "open"
                if state != prev_state:
                    log(f"lid {state.upper()} (SW_LID={event.value})")
                    play_sound(state)
                    prev_state = state
    except OSError as e:
        log(f"OSError: {e}")
    except KeyboardInterrupt:
        log("stopped")


if __name__ == "__main__":
    main()
