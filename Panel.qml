import QtQuick
import Quickshell
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Quill's host: a bar-anchored popup plus an optional real desktop window.
// Note state, backend processes and shortcuts live in Library.qml; this file
// only owns window lifecycle and host injection.
Item {
  id: root

  property var shell: null
  property var hostWidget: null
  property var bar: null
  property var anchorItem: null
  property var manifest: null
  property var settings: ({})

  property bool opened: false
  property bool appWindowOpened: false
  property string pendingMode: ""

  readonly property string pluginId: "matt.quill"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string dataRoot: {
    var override = Quickshell.env("QUILL_DATA_DIR")
    if (override && override.length > 0) {
      if (override === "~") return home
      if (override.indexOf("~/") === 0) return home + override.slice(1)
      return override
    }
    return home + "/.local/share/quill"
  }
  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    return home + "/.config/omarchy/plugins/" + pluginId
  }
  readonly property string storePath: pluginDir + "/scripts/quill-store"
  // Empty means save-triggered Joplin sync is off. A test harness that sets
  // QUILL_JOPLIN_SYNC_PATH opts in explicitly even under QUILL_E2E=1.
  readonly property string joplinSyncPath: {
    var override = Quickshell.env("QUILL_JOPLIN_SYNC_PATH") || ""
    if (override.length > 0) return override
    if (Quickshell.env("QUILL_JOPLIN_AUTOSYNC") === "0") return ""
    if (Quickshell.env("QUILL_E2E") === "1") return ""
    return home + "/.local/bin/quill-joplin-sync"
  }

  function parsePayload(payloadJson) {
    if (!payloadJson) return ({})
    if (typeof payloadJson === "object") return payloadJson
    var raw = String(payloadJson).trim()
    if (!raw) return ({})
    if (raw.charAt(0) === "{") {
      try { return JSON.parse(raw) } catch (error) { return ({}) }
    }
    // Accept the bare mode names too, so `quill open capture` (or a test
    // harness) behaves like the JSON payload the bar sends.
    return ({ mode: raw })
  }

  function open(payloadJson) {
    var payload = parsePayload(payloadJson)
    var mode = String(payload.mode || payload.action || "")
    if (mode === "library") {
      openLibrary()
      return
    }
    pendingMode = mode
    if (appWindowOpened) {
      appWindow.minimized = false
      handlePendingMode()
      return
    }
    opened = true
    library.refreshAll()
    Qt.callLater(function() {
      root.handlePendingMode()
      library.focusInitial()
    })
  }

  function handlePendingMode() {
    if (pendingMode === "capture") {
      pendingMode = ""
      library.capture()
    } else {
      pendingMode = ""
      library.focusInitial()
    }
  }

  function close() {
    library.flushSave()
    if (root.opened) root.opened = false
    if (root.appWindowOpened) root.appWindowOpened = false
  }

  function toggle() {
    if (root.opened || root.appWindowOpened) close()
    else open("")
  }

  function openLibrary() {
    if (appWindowOpened) {
      appWindow.minimized = false
      return
    }
    library.flushSave()
    opened = false
    appWindowOpened = true
    library.refreshAll()
    Qt.callLater(function() {
      appWindow.minimized = false
      library.focusInitial()
    })
  }

  function closeLibraryWindow() {
    library.flushSave()
    appWindowOpened = false
  }

  // Put the expanded window back into the bar popup, keeping the app open.
  function dockLibraryWindow() {
    if (!appWindowOpened) return
    library.flushSave()
    appWindowOpened = false
    opened = true
    library.refreshAll()
    Qt.callLater(function() {
      if (root.opened) library.focusInitial()
    })
  }

  function requestClose() {
    if (appWindowOpened) {
      closeLibraryWindow()
      return
    }
    if (hostWidget && typeof hostWidget.close === "function") hostWidget.close()
    else if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function toggleLibraryWindow() {
    if (appWindowOpened) closeLibraryWindow()
    else openLibrary()
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.hostWidget
    open: root.opened
    centerOnBar: true
    focusTarget: library ? library.focusItem : null
    padding: Style.space(14)
    contentWidth: popup.fittedContentWidth(Style.space(1240))
    contentHeight: popup.cappedContentHeight(Style.space(780))

    Item {
      id: panelHost
      anchors.fill: parent
    }
  }

  FloatingWindow {
    id: appWindow
    visible: root.appWindowOpened
    title: "Quill"
    color: Commons.Color.background
    implicitWidth: Style.space(1240)
    implicitHeight: Style.space(780)
    minimumSize: Qt.size(Style.space(820), Style.space(520))
    onVisibleChanged: if (!visible && root.appWindowOpened) root.closeLibraryWindow()

    Item {
      id: appWindowHost
      anchors.fill: parent
      anchors.margins: Style.space(14)

      Rectangle {
        anchors.fill: parent
        color: Commons.Color.background
        z: -1
      }
    }
  }

  Library {
    id: library
    parent: root.appWindowOpened ? appWindowHost : panelHost
    anchors.fill: parent
    storePath: root.storePath
    dataRoot: root.dataRoot
    joplinSyncPath: root.joplinSyncPath
    // Production shell only. Tests set QUILL_E2E=1, which forces read-only
    // even if this file is instantiated by a harness against the live root.
    allowRealData: Quickshell.env("QUILL_E2E") !== "1"
    inWindow: root.appWindowOpened
    active: root.opened || root.appWindowOpened
    onRequestClose: root.requestClose()
    onRequestLibraryWindow: root.appWindowOpened ? root.dockLibraryWindow() : root.openLibrary()
  }
}
