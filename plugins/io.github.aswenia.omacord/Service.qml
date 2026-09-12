import QtQuick
import Quickshell.Io

// omacord service plugin.
//
// The stylesheet is produced entirely by the hook that Omarchy runs when the
// theme changes, so there is nothing for this component to do per theme
// switch. Its single job is to run the installer once when the shell comes
// up, which is what lets the wiring reappear by itself after Vesktop or
// Vencord recreates its config directory, and what picks up a Discord client
// that was installed after the plugin.
//
// The installer is idempotent and exits in milliseconds when everything is
// already in place, so running it unconditionally costs nothing.
Item {
    id: root

    // Supplied by the shell's plugin loader.
    property var shell: null
    property var manifest: null

    // __sourceDir is set by the loader. Falling back to this file's own
    // location keeps the component usable when it is loaded directly.
    readonly property string pluginDir: {
        if (manifest && manifest.__sourceDir)
            return String(manifest.__sourceDir)
        var here = String(Qt.resolvedUrl("."))
        if (here.startsWith("file://"))
            here = here.substring(7)
        if (here.endsWith("/"))
            here = here.slice(0, -1)
        return decodeURIComponent(here)
    }

    Process {
        id: installer

        command: ["bash", root.pluginDir + "/install.sh"]

        // Only failures are worth surfacing, and only the tail of them: this
        // component lives for the lifetime of the shell, so nothing here may
        // retain output indefinitely.
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var message = String(text || "").trim()
                if (message.length > 0)
                    root.lastError = message.length > 400 ? message.slice(-400) : message
            }
        }

        onExited: function (exitCode) {
            if (exitCode === 0)
                return
            console.warn("omacord: installer exited " + exitCode
                         + (root.lastError.length > 0 ? ": " + root.lastError : ""))
        }
    }

    property string lastError: ""

    // Give the shell a moment to finish starting before touching any config.
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: {
            if (!installer.running) {
                root.lastError = ""
                installer.running = true
            }
        }
    }

    // Removing the plugin intentionally leaves Discord themed. Tearing the
    // stylesheet out from under a running client would be a surprise, and the
    // user may well want to keep the theme. uninstall.sh reverses everything.
}
