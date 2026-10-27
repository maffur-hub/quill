import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Quill's bar entry point. Owns only the button, the lazily loaded panel and
// the IPC surface; all note state lives in Library.qml via Panel.qml.
BarWidget {
  id: root

  moduleName: "matt.quill"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool windowOpen: panelLoader.item ? panelLoader.item.appWindowOpened === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("shell" in target) target.shell = root.bar ? root.bar.shell : null
    if ("hostWidget" in target) target.hostWidget = root
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("settings" in target) target.settings = root.settings
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open("")
  }

  function capture() {
    if (panelLoader.item) panelLoader.item.open(JSON.stringify({ mode: "capture" }))
  }

  function openLibrary() {
    if (panelLoader.item) panelLoader.item.openLibrary()
  }

  // Collapse the expanded window back into the bar popup.
  function dock() {
    if (panelLoader.item && typeof panelLoader.item.dockLibraryWindow === "function") panelLoader.item.dockLibraryWindow()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // `omarchy-shell quill open|capture|toggle|openLibrary` lands here.
  IpcHandler {
    target: "quill"

    function open(): void { root.open() }
    function capture(): void { root.capture() }
    function toggle(): void { root.toggle() }
    function openLibrary(): void { root.openLibrary() }
    function dock(): void { root.dock() }
    function close(): void { root.close() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Quill — notes"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.capture()
      else if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }
}
