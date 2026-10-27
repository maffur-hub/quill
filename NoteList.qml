import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Middle pane: instant search plus the note list.
BorderSurface {
  id: root

  property var notes: []
  property string selectedId: ""
  property string searchText: ""
  property bool searching: false
  property bool showTrash: false
  property bool loading: false

  readonly property bool searchFocused: searchField.activeFocus

  signal noteSelected(string id)
  signal searchQueryChanged(string text)
  signal escapePressed()
  signal editorFocusRequested()
  signal collapseRequested()

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function focusList() {
    root.forceActiveFocus()
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

  function escapeHtml(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  function snippetHtml(value) {
    return root.escapeHtml(value)
      .replace(/⟪/g, "<b>")
      .replace(/⟫/g, "</b>")
  }

  function scrollToSelection() {
    for (var i = 0; i < root.notes.length; i++) {
      if (String(root.notes[i].id) === root.selectedId) {
        noteList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  onSelectedIdChanged: Qt.callLater(scrollToSelection)
  onNotesChanged: Qt.callLater(scrollToSelection)

  color: Util.alpha(Commons.Color.foreground, 0.016)
  borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
  radius: Style.cornerRadius
  focus: true

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
      root.moveSelection(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
      root.moveSelection(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.editorFocusRequested()
      event.accepted = true
    } else if (event.text === "/") {
      root.focusSearch()
      event.accepted = true
    }
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(9)
    spacing: Style.space(7)

    Item {
      width: parent.width
      height: searchField.implicitHeight

      TextField {
        id: searchField
        width: parent.width - collapseButton.width - Style.space(4)
        placeholderText: "Search notes   /"
        font.pixelSize: Style.font.bodySmall
        onTextChanged: root.searchQueryChanged(text)
        Keys.onEscapePressed: function(event) {
          root.escapePressed()
          event.accepted = true
        }
        Keys.onDownPressed: function(event) { root.focusList(); event.accepted = true }
      }

      Button {
        id: collapseButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        height: Style.space(20)
        text: ""
        iconText: "‹"
        iconSize: Style.font.bodySmall
        horizontalPadding: 0
        verticalPadding: 0
        tooltipText: "Hide notes"
        onClicked: root.collapseRequested()
      }
    }

    Item {
      width: parent.width
      height: parent.height - y
      clip: true

      ListView {
        id: noteList
        anchors.fill: parent
        clip: true
        spacing: Style.space(3)
        model: root.notes
        boundsBehavior: Flickable.StopAtBounds

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.editorFocusRequested()
            event.accepted = true
          } else if (event.text === "/") {
            root.focusSearch()
            event.accepted = true
          }
        }

        delegate: BorderSurface {
          id: noteRow
          required property var modelData
          required property int index

          readonly property bool rowSelected: String(modelData.id) === root.selectedId

          width: noteList.width
          height: Style.space(80)
          color: rowSelected
            ? Style.selectedAccentFill
            : rowMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
          borderSpec: rowSelected
            ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
            : rowMouse.containsMouse ? Border.controlSpec("hover-cursor", Commons.Color.foreground, Commons.Color.accent) : Border.none
          radius: Style.cornerRadius

          Rectangle {
            visible: noteRow.rowSelected
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            color: Commons.Color.accent
          }

          Column {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(8)
            anchors.topMargin: Style.space(7)
            anchors.bottomMargin: Style.space(6)
            spacing: Style.space(2)

            Row {
              width: parent.width
              spacing: Style.space(5)

              Text {
                visible: !!noteRow.modelData.pinned
                anchors.verticalCenter: parent.verticalCenter
                text: "◆"
                color: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width - rowDate.width - (noteRow.modelData.pinned ? Style.space(14) : 0)
                anchors.verticalCenter: parent.verticalCenter
                text: String(noteRow.modelData.title || "Untitled")
                textFormat: Text.PlainText
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: noteRow.rowSelected
                elide: Text.ElideRight
              }
              Text {
                id: rowDate
                anchors.verticalCenter: parent.verticalCenter
                text: root.relativeTime(noteRow.modelData.modified)
                color: Util.alpha(Commons.Color.foreground, 0.44)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: parent.width
              height: Style.space(16)
              verticalAlignment: Text.AlignVCenter
              text: root.snippetHtml(String(noteRow.modelData.snippet || "No additional text"))
              textFormat: Text.RichText
              color: Util.alpha(Commons.Color.foreground, 0.56)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(7)
              height: Style.space(14)

              Text {
                visible: String(noteRow.modelData.folder || "") !== ""
                text: String(noteRow.modelData.folder)
                textFormat: Text.PlainText
                color: Util.alpha(Commons.Color.foreground, 0.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width * 0.55)
              }

              Repeater {
                model: noteRow.modelData.tags ? noteRow.modelData.tags.slice(0, 3) : []
                delegate: Text {
                  required property var modelData
                  text: "#" + String(modelData)
                  textFormat: Text.PlainText
                  color: Util.alpha(Commons.Color.accent, 0.72)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.noteSelected(String(noteRow.modelData.id))
              root.forceActiveFocus()
            }
            onDoubleClicked: {
              root.noteSelected(String(noteRow.modelData.id))
              root.editorFocusRequested()
            }
          }
        }
      }

      Column {
        visible: root.notes.length === 0 && !root.loading
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        spacing: Style.space(8)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.searching
            ? "Searching…"
            : root.searchText !== ""
              ? "No notes match this search"
              : root.showTrash
                ? "Trash is empty"
                : "No notes here yet"
          color: Util.alpha(Commons.Color.foreground, 0.46)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }

      Text {
        visible: root.notes.length > 0 && root.showTrash
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(6)
        text: "Restore or delete notes from the header"
        color: Util.alpha(Commons.Color.foreground, 0.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  function clearSearch() {
    searchField.text = ""
  }

  function moveSelection(delta) {
    if (root.notes.length === 0) return
    var index = -1
    for (var i = 0; i < root.notes.length; i++) {
      if (String(root.notes[i].id) === root.selectedId) { index = i; break }
    }
    if (index < 0) index = delta < 0 ? 0 : -1
    index = Math.max(0, Math.min(root.notes.length - 1, index + delta))
    root.noteSelected(String(root.notes[index].id))
    noteList.positionViewAtIndex(index, ListView.Contain)
  }
}
