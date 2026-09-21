#!/usr/bin/env python3
"""Type this VM's generated fixture password through its private QMP socket."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("--work", type=Path, required=True)
args = parser.parse_args()
work = args.work.resolve()
password = (work / "guest-password").read_text()
if not password or any(not (char.isascii() and (char.isalnum() or char in "-_")) for char in password):
    raise SystemExit("Unexpected fixture password format")
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(5)
    connection.connect(str(work / "qmp.sock"))
    stream = connection.makefile("rwb", buffering=0)
    json.loads(stream.readline())
    def request(name, arguments=None):
        stream.write((json.dumps({"execute":name, "arguments":arguments or {}}) + "\n").encode())
        while True:
            reply = json.loads(stream.readline())
            if "error" in reply: raise RuntimeError("QMP fixture input failed")
            if "return" in reply: return
    request("qmp_capabilities")
    def key(name):
        request("human-monitor-command", {"command-line":"sendkey " + name + " 25"})
        time.sleep(0.06)
    key("ret")
    time.sleep(0.3)
    key("ctrl-a")
    key("backspace")
    for char in password:
        key("shift-" + char.lower() if char.isupper() else "shift-minus" if char == "_" else "minus" if char == "-" else char)
    key("ret")
print("Fixture credentials entered into the disposable VM; no credential text was logged.")
