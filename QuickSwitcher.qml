import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Fuzzy.js" as Fuzzy

// Command-palette quick switcher: type to jump to any live note.
//
// The popup only understands ids and titles. Library.qml supplies the title
// index, resolves the chosen id and decides whether to open the note in the
// library or a detached window. Fuzzy.js does the ordering, so an empty query
// keeps the index order (pinned first, then newest).
Popup {
  id: root

  property var entries: []
  property string selectedId: ""
  property bool loading: false
  // 0 = first row, -1 = nothing highlighted (empty results).
  property int highlighted: 0

  readonly property var results: Fuzzy.rank(entries, field.text, function(entry) {
    return String(entry && entry.title ? entry.title : "") + " " +
      String(entry && entry.folder ? entry.folder : "")
  })
  readonly property real rowHeight: Style.space(38)
  readonly property int visibleRows: Math.min(root.results.length, 12)
  readonly property real overlayWidth: Overlay.overlay ? Overlay.overlay.width : 0
  readonly property real overlayHeight: Overlay.overlay ? Overlay.overlay.height : 0

  signal noteChosen(string id, bool detached)
  // Popup already exposes `closed()`; redeclaring it would shadow the base
  // signal and stop it being emitted, so consumers connect to the inherited
  // signal instead.

  objectName: "quickSwitcher"
  parent: Overlay.overlay
  width: overlayWidth > 0
    ? Math.min(Style.space(520), overlayWidth - Style.space(24))
    : Style.space(520)
  // Popup's anchors group has no horizontalCenter in Qt 6, so centre with x.
  x: parent ? Math.round((parent.width - width) / 2) : 0
  y: overlayHeight > 0 ? Math.round(overlayHeight * 0.12) : Style.space(80)
  padding: Style.space(9)
  modal: true
  dim: true
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

  function open() {
    field.text = ""
    highlighted = 0
    root.visible = true
    Qt.callLater(function() {
      field.forceActiveFocus()
      field.selectAll()
    })
  }

  function close() {
    root.visible = false
  }

  function focusField() {
    if (!root.visible) return
    field.forceActiveFocus()
    field.selectAll()
  }

  function moveHighlight(delta) {
    if (root.results.length === 0) {
      root.highlighted = -1
      return
    }
    var next = root.highlighted + delta
    root.highlighted = Math.max(0, Math.min(root.results.length - 1, next))
    resultList.positionViewAtIndex(root.highlighted, ListView.Contain)
  }

  function choose(index, detached) {
    if (index < 0 || index >= root.results.length) return
    var entry = root.results[index]
    var id = entry && entry.id !== undefined && entry.id !== null ? String(entry.id) : ""
    if (id === "") return
    root.noteChosen(id, detached)
    root.close()
  }

  function relativeTime(milliseconds) {
    var value = Number(milliseconds || 0)
    if (!value) return ""
    var date = new Date(value)
    var now = new Date()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (value >= today) return Qt.formatTime(date, "HH:mm")
    if (value >= today - 86400000) return "Yesterday"
    if (date.getFullYear() === now.getFullYear()) return Qt.formatDate(date, "MMM d")
    return Qt.formatDate(date, "yyyy-MM-dd")
  }

  function metaFor(entry) {
    var folder = entry && entry.folder ? String(entry.folder) : "Inbox"
    var date = root.relativeTime(entry ? entry.modified : 0)
    return date === "" ? folder : folder + "  ·  " + date
  }

  // A new query is a new list: start again at the best match.
  onResultsChanged: {
    if (root.results.length === 0) root.highlighted = -1
    else root.highlighted = Math.max(0, Math.min(root.highlighted, root.results.length - 1))
  }

  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  contentItem: Column {
    width: root.availableWidth
    spacing: Style.space(7)

    TextField {
      id: field
      objectName: "quickSwitcherField"
      width: parent.width
      placeholderText: "Jump to note…"
      font.pixelSize: Style.font.body
      onTextChanged: root.highlighted = 0
      onActiveFocusChanged: if (!activeFocus && root.visible) Qt.callLater(root.focusField)
      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Up
            || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
          root.moveHighlight(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down
            || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
          root.moveHighlight(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.choose(root.highlighted, ctrl)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }
      // The window's shortcuts are global; claim the control chord while the
      // switcher owns the keyboard so Ctrl+N creates nothing and Ctrl+P does
      // not toggle a pin. Plain keys still type into the field.
      Keys.onShortcutOverride: function(event) {
        if (event.modifiers & Qt.ControlModifier) event.accepted = true
      }
    }

    ListView {
      id: resultList
      objectName: "quickSwitcherList"
      width: parent.width
      height: root.visibleRows > 0
        ? root.visibleRows * root.rowHeight + (root.visibleRows - 1) * Style.space(2)
        : 0
      visible: root.results.length > 0
      clip: true
      spacing: Style.space(2)
      model: root.results
      boundsBehavior: Flickable.StopAtBounds

      delegate: BorderSurface {
        id: resultRow
        required property var modelData
        required property int index

        readonly property bool rowSelected: index === root.highlighted

        width: resultList.width
        height: root.rowHeight
        color: rowSelected
          ? Style.selectedAccentFill
          : resultMouse.containsMouse
            ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
            : "transparent"
        borderSpec: rowSelected
          ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
          : Border.none
        radius: Style.cornerRadius

        Rectangle {
          visible: resultRow.rowSelected
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(3)
          color: Commons.Color.accent
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(9)
          spacing: Style.space(8)

          Text {
            width: parent.width - metaText.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: String(resultRow.modelData.title || "Untitled")
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: resultRow.rowSelected
            elide: Text.ElideRight
          }
          Text {
            id: metaText
            width: Math.min(implicitWidth, parent.width * 0.45)
            anchors.verticalCenter: parent.verticalCenter
            text: root.metaFor(resultRow.modelData)
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, 0.44)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: resultMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.choose(resultRow.index, false)
          onDoubleClicked: root.choose(resultRow.index, true)
        }
      }
    }

    Text {
      objectName: "quickSwitcherEmpty"
      visible: root.results.length === 0
      width: parent.width
      height: Style.space(28)
      verticalAlignment: Text.AlignVCenter
      text: root.loading && root.entries.length === 0 ? "Loading notes…" : "No matching notes"
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.42)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.space(2)
    }

    Text {
      width: parent.width
      text: "↑↓ move  ·  Enter open  ·  Ctrl+Enter new window"
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.32)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      leftPadding: Style.space(2)
    }
  }
}
