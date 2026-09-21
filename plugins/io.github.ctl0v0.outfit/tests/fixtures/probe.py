#!/usr/bin/env python3
"""Fictional process-tree fixture; never used by the application."""
import os
from pathlib import Path
import signal
import sys
import time

if sys.argv[1] == "descendant":
    if os.fork():
        sys.exit(0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path(sys.argv[2]).write_text(str(os.getpid()))
    print("fixture child", flush=True)
    time.sleep(20)
elif sys.argv[1] == "overflow":
    os.write(1, b"x" * 65536)
    time.sleep(20)
