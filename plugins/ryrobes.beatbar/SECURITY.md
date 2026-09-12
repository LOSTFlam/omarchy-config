# Security and privacy

Beatbar is an unsandboxed Omarchy shell plugin. Installing it means trusting
the QML in this repository with the permissions of your graphical desktop
session. Review the source and the commit you intend to install.

## Data flow

1. `Service.qml` launches the locally installed `cava` executable as the
   current user.
2. CAVA asks PipeWire for the monitor of the default output sink and emits 24
   numeric frequency magnitudes through a local raw stdout stream.
3. The service parses those numbers in memory and exposes them to
   `BarWidget.qml` over Quickshell IPC.
4. The widget renders the spectrum and discards older samples. No audio or
   spectrum history is persisted or transmitted.

Beatbar does not request microphone input, network access, root privileges,
administrator access, polkit rules, or a system service. Its only external
application dependency is `cava`, which must already be available on `PATH`.
The `setpriv` utility supplied by Omarchy's base system sets only a parent-death
signal so the analyzer exits with the shell; it makes no identity or capability
changes.

If CAVA is unavailable, Beatbar asks the existing Omarchy OSD to show one
informational message. This is an in-process shell API call; it does not launch
a notification executable or perform system setup.

## Installation boundary

This repository contains no installer or setup script. Installation is handled
by Omarchy's plugin manager, which places the repository in the user plugin
directory. Beatbar does not invoke a package manager, install its dependency,
modify system files, or rewrite unrelated user configuration.

## Reporting

Please report a security or privacy concern through a private GitHub security
advisory for this repository. Do not include sensitive recordings or logs in a
public issue.
