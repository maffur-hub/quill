import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Themed modal for browsing and restoring note snapshots. Hosts own the note
// state (dirty flags, save queue); this component only reads `versions` and
// asks the store to restore a snapshot. It never takes its own pre-restore
// snapshot: quill-store restore-version already does that.
Popup {
  id: versionHistory
  objectName: "versionHistoryPopup"

  property string storePath: ""
  property string noteId: ""
  property string noteTitle: ""
  property bool canRestore: true

  signal restored(string noteId)

  // Listing state.
  property var versions: []
  property int retention: 50
  property bool loading: false
  property int selectedIndex: -1
  property string errorText: ""
  property string statusText: ""

  // Preview state. `previewPath` is the snapshot currently requested; the
  // FileView result is only accepted while it still matches.
  property string previewPath: ""
  property string previewText: ""

  property bool confirming: false
  property bool restoring: false
  // A refresh requested while a listing is in flight runs when that listing
  // exits, so a restore always ends with a list that includes the pre-restore
  // snapshot.
  property bool refreshPending: false
  // Kept across an asynchronous refresh so the row the user acted on stays
  // selected after the list is rebuilt.
  property string pendingSelectionName: ""

  readonly property var selectedVersion: (selectedIndex >= 0 && selectedIndex < versions.length)
    ? versions[selectedIndex] : null

  parent: Overlay.overlay
  anchors.centerIn: Overlay.overlay
  width: Math.max(Style.space(320),
    Math.min(Style.space(720), (parent ? parent.width : Style.space(760)) - Style.space(40)))
  height: Math.max(Style.space(280),
    Math.min(Style.space(560), (parent ? parent.height : Style.space(600)) - Style.space(40)))
  padding: Style.space(12)
  modal: true
  dim: true
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

  onOpened: {
    versionHistoryList.forceActiveFocus()
  }
  onClosed: {
    versionHistory.confirming = false
  }

  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  function openFor(id, title) {
    versionHistory.noteId = String(id || "")
    versionHistory.noteTitle = String(title || "")
    versionHistory.versions = []
    versionHistory.retention = 50
    versionHistory.selectedIndex = -1
    versionHistory.previewPath = ""
    versionHistory.previewText = ""
    versionHistory.errorText = ""
    versionHistory.statusText = ""
    versionHistory.confirming = false
    versionHistory.restoring = false
    versionHistory.pendingSelectionName = ""
    versionHistory.open()
    versionHistory.refresh()
  }

  function refresh() {
    if (versionHistory.storePath === "" || versionHistory.noteId === "") {
      versionHistory.versions = []
      versionHistory.loading = false
      versionHistory.refreshPending = false
      return
    }
    if (versionsProcess.running) {
      versionHistory.refreshPending = true
      return
    }
    versionHistory.refreshPending = false
    versionHistory.loading = true
    versionHistory.errorText = ""
    versionsProcess.requestId = versionHistory.noteId
    versionsProcess.command = [versionHistory.storePath, "versions", versionHistory.noteId]
    versionsProcess.running = true
  }

  function selectVersion(index) {
    if (index < 0 || index >= versionHistory.versions.length) return
    versionHistory.selectedIndex = index
    versionHistory.confirming = false
    versionHistory.errorText = ""
    var version = versionHistory.selectedVersion
    var path = version ? String(version.path || "") : ""
    if (path !== versionHistory.previewPath) {
      versionHistory.previewPath = path
      versionHistory.previewText = ""
    }
  }

  function stepSelection(delta) {
    if (versionHistory.versions.length === 0) return
    var next = versionHistory.selectedIndex + delta
    if (next < 0) next = 0
    if (next > versionHistory.versions.length - 1) next = versionHistory.versions.length - 1
    versionHistory.selectVersion(next)
  }

  function versionTimestamp(version) {
    if (!version) return ""
    return Qt.formatDateTime(new Date(Number(version.mtime || 0)), "yyyy-MM-dd HH:mm:ss")
  }

  function versionSize(version) {
    if (!version) return ""
    var kb = Number(version.size || 0) / 1024
    return (kb < 10 ? kb.toFixed(1) : Math.round(kb)) + " KB"
  }

  function applyVersions(exitCode, outputText, errorText) {
    versionHistory.loading = false
    if (exitCode !== 0) {
      versionHistory.errorText = versionHistory.parseError(errorText, "Could not read version history")
      return
    }
    var result = {}
    try {
      result = JSON.parse(outputText || "{}")
    } catch (error) {
      versionHistory.errorText = "Could not read version history"
      return
    }
    versionHistory.versions = Array.isArray(result.versions) ? result.versions : []
    versionHistory.retention = Number(result.retention || 50)

    var wanted = versionHistory.pendingSelectionName
    if (wanted !== "") {
      var found = -1
      for (var i = 0; i < versionHistory.versions.length; i += 1) {
        if (String(versionHistory.versions[i].name || "") === wanted) { found = i; break }
      }
      versionHistory.selectVersion(found >= 0 ? found : 0)
    } else if (versionHistory.selectedIndex >= versionHistory.versions.length) {
      versionHistory.selectedIndex = -1
      versionHistory.previewPath = ""
      versionHistory.previewText = ""
    }
  }

  function parseError(errorText, fallback) {
    var raw = String(errorText || "").trim()
    if (raw !== "") {
      try {
        var parsed = JSON.parse(raw)
        if (parsed && parsed.error) return String(parsed.error)
      } catch (error) {
        // Not JSON: use the raw message.
      }
      return raw
    }
    return fallback
  }

  function performRestore() {
    if (!versionHistory.selectedVersion || !versionHistory.canRestore || versionHistory.restoring) return
    if (!versionHistory.confirming) {
      versionHistory.confirming = true
      versionHistory.errorText = ""
      versionHistory.statusText = ""
      return
    }
    var version = versionHistory.selectedVersion
    versionHistory.restoring = true
    versionHistory.errorText = ""
    versionHistory.statusText = ""
    restoreProcess.targetName = String(version.name || "")
    restoreProcess.targetMtime = Number(version.mtime || 0)
    restoreProcess.command = [versionHistory.storePath, "restore-version",
      versionHistory.noteId, restoreProcess.targetName]
    restoreProcess.running = true
  }

  function finishRestore(exitCode, outputText, errorText) {
    versionHistory.restoring = false
    if (exitCode !== 0) {
      versionHistory.errorText = versionHistory.parseError(errorText, "Could not restore this version")
      return
    }
    var timestamp = Qt.formatDateTime(new Date(Number(restoreProcess.targetMtime || 0)),
      "yyyy-MM-dd HH:mm:ss")
    versionHistory.confirming = false
    versionHistory.errorText = ""
    versionHistory.statusText = "Restored version from " + timestamp
    // Keep the restored snapshot selected once the fresh list (which now also
    // contains the pre-restore snapshot) arrives.
    versionHistory.pendingSelectionName = String(restoreProcess.targetName || "")
    versionHistory.restored(versionHistory.noteId)
    versionHistory.refresh()
  }

  contentItem: Item {
    width: versionHistory.availableWidth
    height: versionHistory.availableHeight

    Column {
      id: layout
      anchors.fill: parent
      spacing: Style.space(10)

      Column {
        id: headerBlock
        width: parent.width
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: "Version history"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: versionHistory.noteTitle !== "" ? versionHistory.noteTitle : "Untitled"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: "Newest " + versionHistory.retention + " snapshots are kept."
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: bodyRow
        width: parent.width
        height: Math.max(0, parent.height - headerBlock.height - footerRow.height
          - layout.spacing * 2)
        spacing: Style.space(10)

        BorderSurface {
          id: listPane
          width: Math.max(Style.space(170),
            Math.min(Style.space(280), Math.floor((bodyRow.width - bodyRow.spacing) * 0.42)))
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.022)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ListView {
            id: versionHistoryList
            objectName: "versionHistoryList"
            anchors.fill: parent
            anchors.margins: Style.space(4)
            clip: true
            spacing: Style.space(2)
            model: versionHistory.versions
            boundsBehavior: Flickable.StopAtBounds

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Up) {
                versionHistory.stepSelection(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                versionHistory.stepSelection(1)
                event.accepted = true
              }
            }

            delegate: BorderSurface {
              id: versionRow
              required property var modelData
              required property int index

              readonly property bool rowSelected: versionHistory.selectedIndex === index

              objectName: "versionHistoryRow-" + String(modelData.name || index)
              width: versionHistoryList.width
              height: Style.space(44)
              color: rowSelected
                ? Style.selectedAccentFill
                : rowMouse.containsMouse
                  ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                  : "transparent"
              borderSpec: rowSelected
                ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
                : Border.none()
              radius: Style.cornerRadius

              Rectangle {
                visible: versionRow.rowSelected
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.space(3)
                color: Commons.Color.accent
              }

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(9)
                anchors.rightMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  width: parent.width
                  text: versionHistory.versionTimestamp(versionRow.modelData)
                  textFormat: Text.PlainText
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: versionHistory.versionSize(versionRow.modelData)
                  textFormat: Text.PlainText
                  color: Util.alpha(Commons.Color.foreground, 0.42)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: versionHistory.selectVersion(versionRow.index)
              }
            }
          }

          Text {
            objectName: "versionHistoryEmpty"
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            visible: !versionHistory.loading && versionHistory.versions.length === 0
              && versionHistory.errorText === ""
            text: "No versions yet — Quill snapshots a note before it is overwritten."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            visible: versionHistory.loading && versionHistory.versions.length === 0
            text: "Loading versions…"
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            color: Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        BorderSurface {
          id: previewPane
          width: parent.width - listPane.width - parent.spacing
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.022)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ScrollView {
            id: previewScroll
            anchors.fill: parent
            anchors.margins: Style.space(1)
            clip: true
            background: null
            visible: !!versionHistory.selectedVersion

            TextArea {
              objectName: "versionHistoryPreview"
              width: previewScroll.availableWidth
              text: versionHistory.previewText
              textFormat: TextEdit.PlainText
              readOnly: true
              wrapMode: TextArea.Wrap
              selectByMouse: true
              color: Commons.Color.foreground
              selectionColor: Style.selectionFillFor(Commons.Color.foreground, Commons.Color.accent)
              selectedTextColor: Commons.Color.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              padding: Style.space(8)
              background: null
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            visible: !versionHistory.selectedVersion
            text: "Select a version to preview it."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        id: footerRow
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: Math.max(0, parent.width - versionHistoryRestoreButton.width
            - versionHistoryCloseButton.width - parent.spacing * 2)
          anchors.verticalCenter: parent.verticalCenter
          text: versionHistory.errorText !== ""
            ? versionHistory.errorText
            : versionHistory.statusText !== ""
              ? versionHistory.statusText
              : (!versionHistory.canRestore && !versionHistory.restoring
                ? "Waiting for the current note to save…" : "")
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: versionHistory.errorText !== ""
            ? Commons.Color.urgent
            : Util.alpha(Commons.Color.foreground, 0.48)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Button {
          id: versionHistoryCloseButton
          objectName: "versionHistoryCloseButton"
          anchors.verticalCenter: parent.verticalCenter
          text: "Close"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: versionHistory.close()
        }

        Button {
          id: versionHistoryRestoreButton
          objectName: "versionHistoryRestoreButton"
          anchors.verticalCenter: parent.verticalCenter
          text: versionHistory.restoring
            ? "Restoring…"
            : versionHistory.confirming ? "Confirm restore" : "Restore"
          active: versionHistory.confirming
          enabled: !!versionHistory.selectedVersion && versionHistory.canRestore
            && !versionHistory.restoring
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: versionHistory.performRestore()
        }
      }
    }
  }

  Process {
    id: versionsProcess
    property string requestId: ""
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: versionsProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: versionsProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      if (versionsProcess.requestId === versionHistory.noteId) {
        versionHistory.applyVersions(exitCode, versionsProcess.outputText, versionsProcess.errorText)
      }
      if (versionHistory.refreshPending) {
        versionHistory.refreshPending = false
        versionHistory.refresh()
      }
    }
  }

  Process {
    id: restoreProcess
    property string outputText: ""
    property string errorText: ""
    property string targetName: ""
    property real targetMtime: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: restoreProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: restoreProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      versionHistory.finishRestore(exitCode, restoreProcess.outputText, restoreProcess.errorText)
    }
  }

  FileView {
    id: previewFile
    path: versionHistory.previewPath
    printErrors: false
    onLoaded: {
      if (String(previewFile.path) !== versionHistory.previewPath) return
      if (!versionHistory.selectedVersion) return
      if (String(versionHistory.selectedVersion.path || "") !== versionHistory.previewPath) return
      versionHistory.previewText = String(text())
    }
  }
}
