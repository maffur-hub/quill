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
  // Multi-selection owned by Library. `selectedId` remains the active row the
  // editor shows; this array is only the additional Shift/Ctrl selection.
  property var selectedIds: []
  property string searchText: ""
  property bool searching: false
  property bool showTrash: false
  property bool loading: false
  property var folderOptions: []

  readonly property bool searchFocused: searchField.activeFocus
  // The array bound to the list model. Library binds this to visibleNotes, so
  // filtered/search views are already the right source for row lookups.
  readonly property var visibleNotes: notes
  property real menuAnchorX: 0
  property real menuAnchorY: 0

  // Saved searches and "advanced search" set searchText from outside; mirror
  // that into the field so the box never disagrees with the results. The
  // equality guard stops the textChanged signal from bouncing back.
  onSearchTextChanged: if (searchField.text !== root.searchText) searchField.text = root.searchText

  signal noteSelected(string id)
  signal selectionToggleRequested(string id)
  signal selectionRangeRequested(string id)
  signal selectAllRequested()
  signal selectionCleared()
  signal searchQueryChanged(string text)
  signal escapePressed()
  signal editorFocusRequested()
  signal collapseRequested()
  signal noteActionRequested(string id, string action)
  signal noteRenameRequested(string id)
  signal noteMoveRequested(string id, string folder)

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function focusList() {
    root.forceActiveFocus()
  }

  function isSelected(id) {
    var key = String(id || "")
    if (key === "") return false
    for (var i = 0; i < root.selectedIds.length; i++) {
      if (String(root.selectedIds[i]) === key) return true
    }
    return false
  }

  // The row a plain Up/Down or Shift+Up/Down should land on. Shift ranges are
  // extended by Library, so this only computes the next id and keeps it
  // visible.
  function adjacentId(delta) {
    if (root.notes.length === 0) return ""
    var index = -1
    for (var i = 0; i < root.notes.length; i++) {
      if (String(root.notes[i].id) === root.selectedId) { index = i; break }
    }
    if (index < 0) index = delta < 0 ? 0 : -1
    index = Math.max(0, Math.min(root.notes.length - 1, index + delta))
    var id = String(root.notes[index].id)
    noteList.positionViewAtIndex(index, ListView.Contain)
    return id
  }

  // A dragged row carries the whole selection when it is part of one of two or
  // more rows; otherwise it carries just itself.
  function dragPayload(id) {
    var key = String(id || "")
    if (root.selectedIds.length > 1 && root.isSelected(key)) {
      var ids = []
      for (var i = 0; i < root.selectedIds.length; i++) ids.push(String(root.selectedIds[i]))
      return ids.join("\n")
    }
    return key
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

  function noteSnippetHtml(note) {
    var value = String(note && note.snippet ? note.snippet : "No additional text")
    return root.snippetHtml(note && note.fuzzy ? "≈ " + value : value)
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

  // Position a popup at a point in overlay coordinates, flipping it above or
  // to the left of the pointer when the window edge is close.
  function popupPoint(menu, point) {
    var overlay = Overlay.overlay
    if (!overlay) return Qt.point(0, 0)
    var margin = Style.space(4)
    var width = menu.width > 0 ? menu.width : menu.implicitWidth
    var height = menu.implicitHeight
    var x = Number(point.x || 0)
    var y = Number(point.y || 0)
    if (x + width + margin > overlay.width) x -= width
    if (y + height + margin > overlay.height) y -= height
    x = Math.max(margin, Math.min(x, overlay.width - width - margin))
    y = Math.max(margin, Math.min(y, overlay.height - height - margin))
    return Qt.point(x, y)
  }

  function openNoteMenu(note, point) {
    if (!note) return
    var trashed = !!root.showTrash || !!note.trashed
    var menu = trashed ? trashMenu : noteMenu
    menu.menuNoteId = String(note.id || "")
    // A right-click inside a multi-selection keeps it and shows plural labels.
    menu.bulkCount = root.selectedIds.length > 1 && root.isSelected(String(note.id))
      ? root.selectedIds.length : 1
    if (!trashed) {
      // The bulk label must match pinNotes()'s rule: only unpin when every
      // selected note is already pinned.
      if (menu.bulkCount > 1) {
        var allPinned = true
        for (var s = 0; s < root.selectedIds.length; s++) {
          var selectedNote = null
          for (var n = 0; n < root.notes.length; n++) {
            if (String(root.notes[n].id) === String(root.selectedIds[s])) {
              selectedNote = root.notes[n]
              break
            }
          }
          if (!selectedNote || !selectedNote.pinned) { allPinned = false; break }
        }
        menu.menuPinned = allPinned
      } else {
        menu.menuPinned = !!note.pinned
      }
    }
    root.menuAnchorX = Number(point.x || 0)
    root.menuAnchorY = Number(point.y || 0)
    var target = root.popupPoint(menu, point)
    menu.popup(target.x, target.y)
  }

  function openMenuForSelection() {
    var list = root.visibleNotes
    if (list.length === 0 || root.selectedId === "") return
    var index = -1
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === root.selectedId) { index = i; break }
    }
    if (index < 0) return
    var overlay = Overlay.overlay
    if (!overlay) return
    var row = noteList.itemAtIndex(index)
    var point = row
      ? row.mapToItem(overlay, Style.space(12), row.height)
      : noteList.mapToItem(overlay, Style.space(12), noteList.height / 2)
    root.openNoteMenu(list[index], point)
  }

  function openMoveMenu() {
    if (noteMenu.menuNoteId === "") return
    folderMenu.menuNoteId = noteMenu.menuNoteId
    folderMenu.rebuild()
    var target = root.popupPoint(folderMenu, Qt.point(root.menuAnchorX, root.menuAnchorY))
    folderMenu.popup(target.x, target.y)
  }

  color: Util.alpha(Commons.Color.foreground, 0.016)
  borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
  radius: Style.cornerRadius
  focus: true

  Keys.onPressed: function(event) {
    var command = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)
    if (event.key === Qt.Key_A && command) {
      root.selectAllRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      if (root.selectedIds.length > 1) root.selectionCleared()
      else root.escapePressed()
      event.accepted = true
    } else if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down)
      && (event.modifiers & Qt.ShiftModifier)) {
      var rangeId = root.adjacentId(event.key === Qt.Key_Up ? -1 : 1)
      if (rangeId !== "") root.selectionRangeRequested(rangeId)
      event.accepted = true
    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
      root.moveSelection(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
      root.moveSelection(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.editorFocusRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Menu
      || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
      root.openMenuForSelection()
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
        objectName: "noteList"
        anchors.fill: parent
        clip: true
        spacing: Style.space(3)
        model: root.notes
        boundsBehavior: Flickable.StopAtBounds

        Keys.onPressed: function(event) {
          var command = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)
          if (event.key === Qt.Key_A && command) {
            root.selectAllRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.selectedIds.length > 1) root.selectionCleared()
            else root.escapePressed()
            event.accepted = true
          } else if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down)
            && (event.modifiers & Qt.ShiftModifier)) {
            var rangeId = root.adjacentId(event.key === Qt.Key_Up ? -1 : 1)
            if (rangeId !== "") root.selectionRangeRequested(rangeId)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.editorFocusRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Menu
            || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.openMenuForSelection()
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

          readonly property bool rowActive: String(modelData.id) === root.selectedId
          readonly property bool rowSelected: rowActive || root.isSelected(String(modelData.id))

          objectName: "noteRow-" + String(modelData.id)
          width: noteList.width
          height: Style.space(80)
          color: rowActive
            ? Style.selectedAccentFill
            : rowSelected
              ? Util.alpha(Commons.Color.accent, 0.14)
              : rowMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
          borderSpec: rowActive
            ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
            : rowSelected
              ? Border.flat(Util.alpha(Commons.Color.accent, 0.4), 1)
              : rowMouse.containsMouse ? Border.controlSpec("hover-cursor", Commons.Color.foreground, Commons.Color.accent) : Border.none
          radius: Style.cornerRadius

          Drag.active: rowMouse.dragStarted
          Drag.dragType: Drag.Internal
          Drag.supportedActions: Qt.MoveAction
          Drag.proposedAction: Qt.MoveAction
          Drag.hotSpot: Qt.point(Style.space(12), Style.space(12))
          Drag.keys: ["text/x-quill-note"]
          Drag.mimeData: ({ "text/x-quill-note": root.dragPayload(String(modelData.id)) })

          Rectangle {
            visible: noteRow.rowActive
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
                font.bold: noteRow.rowActive
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
              text: root.noteSnippetHtml(noteRow.modelData)
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
            property bool dragStarted: false
            property real pressX: 0
            property real pressY: 0

            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onPressed: function(mouse) {
              if (mouse.button === Qt.LeftButton) {
                root.forceActiveFocus()
                dragStarted = false
                pressX = mouse.x
                pressY = mouse.y
                return
              }
              if (mouse.button !== Qt.RightButton) return
              var id = String(noteRow.modelData.id)
              // Right-click inside a multi-selection keeps it; anywhere else it
              // selects just this row first, exactly like a plain click.
              if (!root.isSelected(id) || root.selectedIds.length < 2) {
                root.noteSelected(id)
              }
              root.forceActiveFocus()
              var overlay = Overlay.overlay
              if (!overlay) return
              var point = noteRow.mapToItem(overlay, mouse.x, mouse.y)
              root.openNoteMenu(noteRow.modelData, point)
              mouse.accepted = true
            }
            onPositionChanged: function(mouse) {
              if (!pressed || dragStarted) return
              if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(4)) return
              // A real drag suppresses the click that would otherwise reset
              // the selection under the pointer.
              dragStarted = true
            }
            onReleased: {
              if (!dragStarted) return
              // Let onClicked see the flag first; it is what suppresses the
              // accidental click after a drop.
              Qt.callLater(function() { rowMouse.dragStarted = false })
            }
            onClicked: function(mouse) {
              if (mouse.button !== Qt.LeftButton) return
              if (dragStarted) {
                dragStarted = false
                return
              }
              var id = String(noteRow.modelData.id)
              if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                root.selectionToggleRequested(id)
                return
              }
              if (mouse.modifiers & Qt.ShiftModifier) {
                root.selectionRangeRequested(id)
                return
              }
              root.noteSelected(id)
            }
            onDoubleClicked: function(mouse) {
              if (mouse.button !== Qt.LeftButton) return
              if (dragStarted) return
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

  // -------------------------------------------------------- context menus
  Menu {
    id: noteMenu
    objectName: "noteListMenu"
    parent: Overlay.overlay
    property string menuNoteId: ""
    property bool menuPinned: false
    property int bulkCount: 1
    width: Style.space(220)
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    palette.window: Commons.Color.menu.background
    palette.windowText: Commons.Color.menu.text
    palette.text: Commons.Color.menu.text
    palette.buttonText: Commons.Color.menu.text
    palette.light: Commons.Color.menu.selectedBackground
    palette.midlight: Util.alpha(Commons.Color.foreground, 0.12)
    palette.mid: Util.alpha(Commons.Color.foreground, 0.16)
    palette.dark: Commons.Color.menu.border

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    ContextMenuItem {
      objectName: "noteMenuPin"
      text: noteMenu.bulkCount > 1
        ? (noteMenu.menuPinned
          ? "Unpin " + noteMenu.bulkCount + " notes"
          : "Pin " + noteMenu.bulkCount + " notes")
        : (noteMenu.menuPinned ? "Unpin" : "Pin")
      onTriggered: root.noteActionRequested(noteMenu.menuNoteId, "pin")
    }
    ContextMenuItem {
      objectName: "noteMenuRename"
      text: "Rename…"
      visible: noteMenu.bulkCount <= 1
      onTriggered: root.noteRenameRequested(noteMenu.menuNoteId)
    }
    ContextMenuItem {
      objectName: "noteMenuDuplicate"
      text: "Duplicate"
      visible: noteMenu.bulkCount <= 1
      onTriggered: root.noteActionRequested(noteMenu.menuNoteId, "duplicate")
    }
    ContextMenuItem {
      objectName: "noteMenuMove"
      text: noteMenu.bulkCount > 1
        ? "Move " + noteMenu.bulkCount + " notes to folder…" : "Move to folder…"
      onTriggered: root.openMoveMenu()
    }
    ContextMenuItem {
      objectName: "noteMenuTagAdd"
      text: "Add tag…"
      onTriggered: root.noteActionRequested(noteMenu.menuNoteId, "tag-add")
    }
    ContextMenuItem {
      objectName: "noteMenuTagRemove"
      text: "Remove tag…"
      onTriggered: root.noteActionRequested(noteMenu.menuNoteId, "tag-remove")
    }

    MenuSeparator {
      objectName: "noteMenuSeparator"
    }

    ContextMenuItem {
      objectName: "noteMenuTrash"
      text: noteMenu.bulkCount > 1
        ? "Move " + noteMenu.bulkCount + " notes to Trash" : "Move to Trash"
      onTriggered: root.noteActionRequested(noteMenu.menuNoteId, "trash")
    }

    MenuSeparator {
      objectName: "noteMenuSelectAllSeparator"
      visible: root.notes.length > 1
    }

    ContextMenuItem {
      objectName: "noteMenuSelectAll"
      text: "Select all"
      visible: root.notes.length > 1
      onTriggered: root.selectAllRequested()
    }
  }

  Menu {
    id: trashMenu
    objectName: "noteListTrashMenu"
    parent: Overlay.overlay
    property string menuNoteId: ""
    property int bulkCount: 1
    width: Style.space(220)
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    palette.window: Commons.Color.menu.background
    palette.windowText: Commons.Color.menu.text
    palette.text: Commons.Color.menu.text
    palette.buttonText: Commons.Color.menu.text
    palette.light: Commons.Color.menu.selectedBackground
    palette.midlight: Util.alpha(Commons.Color.foreground, 0.12)
    palette.mid: Util.alpha(Commons.Color.foreground, 0.16)
    palette.dark: Commons.Color.menu.border

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    ContextMenuItem {
      objectName: "trashNoteMenuRestore"
      text: trashMenu.bulkCount > 1
        ? "Restore " + trashMenu.bulkCount + " notes" : "Restore"
      onTriggered: root.noteActionRequested(trashMenu.menuNoteId, "restore")
    }

    MenuSeparator {
      objectName: "trashNoteMenuSeparator"
    }

    ContextMenuItem {
      objectName: "trashNoteMenuDelete"
      text: trashMenu.bulkCount > 1
        ? "Delete " + trashMenu.bulkCount + " notes forever…" : "Delete forever…"
      onTriggered: root.noteActionRequested(trashMenu.menuNoteId, "delete-forever")
    }
  }

  // A real submenu cannot be built from a dynamic folder list in QML, so the
  // folder chooser is a second themed menu opened beside the pointer.
  Menu {
    id: folderMenu
    objectName: "noteListFolderMenu"
    parent: Overlay.overlay
    property string menuNoteId: ""
    width: Style.space(220)
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    palette.window: Commons.Color.menu.background
    palette.windowText: Commons.Color.menu.text
    palette.text: Commons.Color.menu.text
    palette.buttonText: Commons.Color.menu.text
    palette.light: Commons.Color.menu.selectedBackground
    palette.midlight: Util.alpha(Commons.Color.foreground, 0.12)
    palette.mid: Util.alpha(Commons.Color.foreground, 0.16)
    palette.dark: Commons.Color.menu.border

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    function rebuild() {
      while (count > 0) removeItem(itemAt(count - 1))
      for (var i = 0; i < root.folderOptions.length; i++) {
        var option = root.folderOptions[i] || {}
        var value = option.value === undefined || option.value === null
          ? "" : String(option.value)
        var label = option.label === undefined || option.label === null
          ? value : String(option.label)
        var item = folderMenuItemComponent.createObject(null, {
          "text": label,
          "objectName": "noteMoveFolderItem-" + i,
          "folderValue": value
        })
        if (item) addItem(item)
      }
    }
  }

  Component {
    id: folderMenuItemComponent
    ContextMenuItem {
      id: folderItem
      property string folderValue: ""
      onTriggered: {
        var noteId = folderMenu.menuNoteId
        folderMenu.close()
        if (noteId !== "") root.noteMoveRequested(noteId, folderItem.folderValue)
      }
    }
  }

  function clearSearch() {
    searchField.text = ""
  }

  function moveSelection(delta) {
    var id = root.adjacentId(delta)
    if (id !== "") root.noteSelected(id)
  }
}
