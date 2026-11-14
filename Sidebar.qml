import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TagTree.js" as TagTree
import "PopupAnchor.js" as PopupAnchor

// Left library rail: saved views, tag counts and the folder tree.
BorderSurface {
  id: root

  property var notes: []
  property var folders: []
  property var tags: []
  property var savedSearches: []
  property string activeSearch: ""
  property string category: "all"
  property int trashCount: 0

  signal categorySelected(string category)
  signal createFolderRequested(string path)
  signal renameFolderRequested(string path, string next)
  signal deleteFolderRequested(string path)
  signal savedSearchSelected(string query)
  signal savedSearchRemoveRequested(string query)
  signal savedSearchSaveRequested()
  // Pure parent rows open a subtree; leaves keep using categorySelected.
  signal tagSubtreeSelected(string prefix)
  signal tagActionRequested(string tag, string action)
  signal collapseRequested()
  // Payload is newline-separated note ids; folder is "" for the Inbox.
  signal noteDropRequested(string payload, string folder)

  property string renamingPath: ""
  property bool creatingFolder: false
  property string tagMenuTag: ""

  readonly property int pinnedCount: countWhere(function(note) { return !!note.pinned })
  readonly property int recentCount: countWhere(function(note) { return Date.now() - Number(note.modified || 0) < 7 * 86400000 })

  function countWhere(predicate) {
    var total = 0
    for (var i = 0; i < notes.length; i++) if (!notes[i].trashed && predicate(notes[i])) total += 1
    return total
  }

  function folderCount(path) {
    return countWhere(function(note) { return String(note.folder || "") === path })
  }

  function folderDepth(path) {
    return String(path).split("/").length - 1
  }

  function folderLeaf(path) {
    var parts = String(path).split("/")
    return parts[parts.length - 1]
  }

  function beginRename(path) {
    renamingPath = path
  }

  // Place the tag menu under its row, flipping it when the window edge is
  // close. The menu lives on the overlay so it can paint past the sidebar.
  function openTagMenu(tag, row) {
    var overlay = Overlay.overlay
    if (!overlay || !row) return
    PopupAnchor.anchor(tagMenu, overlay)
    tagMenuTag = String(tag)
    var point = row.mapToItem(overlay, Style.space(8), row.height)
    var margin = Style.space(4)
    var width = tagMenu.width > 0 ? tagMenu.width : tagMenu.implicitWidth
    var height = tagMenu.implicitHeight
    var x = Number(point.x || 0)
    var y = Number(point.y || 0)
    if (x + width + margin > overlay.width) x -= width
    if (y + height + margin > overlay.height) y -= height
    x = Math.max(margin, Math.min(x, overlay.width - width - margin))
    y = Math.max(margin, Math.min(y, overlay.height - height - margin))
    tagMenu.popup(x, y)
  }

  function focusFirst() {
    allRow.forceActiveFocus()
    allRow.rowFocus = true
  }

  color: Util.alpha(Commons.Color.foreground, 0.022)
  borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
  radius: Style.cornerRadius
  focus: true

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(10)
    spacing: Style.space(3)

    Item {
      width: parent.width
      height: Style.space(24)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "LIBRARY"
        color: Util.alpha(Commons.Color.foreground, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Button {
        id: collapseButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        height: Style.space(18)
        text: ""
        iconText: "‹"
        iconSize: Style.font.bodySmall
        horizontalPadding: 0
        verticalPadding: 0
        tooltipText: "Hide library"
        onClicked: root.collapseRequested()
      }
    }

    SideRow {
      id: allRow
      label: "All notes"
      count: root.notes.length
      selected: root.category === "all"
      onActivated: root.categorySelected("all")
    }
    SideRow {
      label: "Pinned"
      count: root.pinnedCount
      selected: root.category === "pinned"
      onActivated: root.categorySelected("pinned")
    }
    SideRow {
      label: "Recent"
      count: root.recentCount
      selected: root.category === "recent"
      onActivated: root.categorySelected("recent")
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Util.alpha(Commons.Color.foreground, 0.1)
    }

    Flickable {
      id: railFlick
      width: parent.width
      height: Math.max(0, parent.height - y - trashRow.height - Style.space(6))
      clip: true
      contentWidth: width
      contentHeight: railContent.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: railContent
        width: railFlick.width
        spacing: Style.space(3)

        Row {
          width: parent.width
          height: Style.space(24)

          Text {
            width: parent.width - (saveSearchButton.visible ? saveSearchButton.width : 0)
            anchors.verticalCenter: parent.verticalCenter
            text: "SEARCHES"
            color: Util.alpha(Commons.Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Button {
            id: saveSearchButton
            objectName: "saveSearchButton"
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            height: Style.space(18)
            text: ""
            iconText: "＋"
            iconSize: Style.font.bodySmall
            horizontalPadding: 0
            verticalPadding: 0
            visible: root.activeSearch.trim() !== ""
            enabled: visible
            tooltipText: "Save current search"
            onClicked: root.savedSearchSaveRequested()
          }
        }

        Text {
          visible: root.savedSearches.length === 0
          width: parent.width
          text: "No saved searches"
          color: Util.alpha(Commons.Color.foreground, 0.32)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          leftPadding: Style.space(8)
        }

        Repeater {
          model: root.savedSearches
          delegate: SideRow {
            required property var modelData
            label: String(modelData.label || modelData.query)
            count: 0
            showCount: false
            indent: 4
            actionText: "×"
            selected: root.activeSearch.trim() !== ""
              && root.activeSearch.trim() === String(modelData.query)
            onActivated: root.savedSearchSelected(String(modelData.query))
            onActionTriggered: root.savedSearchRemoveRequested(String(modelData.query))
          }
        }

        Item { width: 1; height: Style.space(6) }

        Text {
          width: parent.width
          height: Style.space(24)
          verticalAlignment: Text.AlignVCenter
          text: "TAGS"
          color: Util.alpha(Commons.Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          visible: root.tags.length === 0
          width: parent.width
          text: "No tags yet — write #tag"
          color: Util.alpha(Commons.Color.foreground, 0.32)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          leftPadding: Style.space(8)
        }

        Repeater {
          model: TagTree.build(root.tags)
          delegate: SideRow {
            id: tagRow
            required property var modelData
            readonly property string tagPath: String(modelData.path)
            readonly property bool realTag: modelData.isLeaf === true

            label: "#" + String(modelData.label)
            count: Number(modelData.count) || 0
            showCount: true
            indent: 4 + Number(modelData.depth) * 10
            actionText: realTag ? "⋯" : ""
            actionColor: Commons.Color.foreground
            selected: realTag
              ? root.category === "tag:" + tagPath
              : root.category === "tagtree:" + tagPath
            onActivated: {
              if (realTag) root.categorySelected("tag:" + tagPath)
              else root.tagSubtreeSelected(tagPath)
            }
            onActionTriggered: root.openTagMenu(tagPath, tagRow)
            onRightClicked: {
              if (realTag) root.openTagMenu(tagPath, tagRow)
            }
          }
        }

        Item { width: 1; height: Style.space(6) }

        Row {
          width: parent.width
          height: Style.space(24)

          Text {
            width: parent.width - addFolder.width
            anchors.verticalCenter: parent.verticalCenter
            text: "FOLDERS"
            color: Util.alpha(Commons.Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            id: addFolder
            anchors.verticalCenter: parent.verticalCenter
            text: "+"
            color: addFolderMouse.containsMouse ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            MouseArea {
              id: addFolderMouse
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.creatingFolder = true
                Qt.callLater(function() { newFolderField.forceActiveFocus() })
              }
            }
          }
        }

        TextField {
          id: newFolderField
          visible: root.creatingFolder
          width: parent.width
          placeholderText: "Folder or nested/path"
          font.pixelSize: Style.font.bodySmall
          onAccepted: {
            var value = String(text || "").trim()
            if (value) root.createFolderRequested(value)
            text = ""
            root.creatingFolder = false
          }
          Keys.onEscapePressed: function(event) {
            root.creatingFolder = false
            text = ""
            event.accepted = true
          }
        }

        SideRow {
          label: "Inbox"
          count: root.folderCount("")
          selected: root.category === "folder:"
          dropEnabled: true
          dropFolder: ""
          onActivated: root.categorySelected("folder:")
          onDropRequested: function(payload, folder) {
            root.noteDropRequested(payload, folder)
          }
        }

        Repeater {
          model: root.folders
          delegate: Item {
            id: folderItem
            required property var modelData
            readonly property string path: String(modelData)
            property bool dropActive: false
            width: parent.width
            height: root.renamingPath === path ? Style.space(34) : Style.space(30)

            TextField {
              id: renameField
              visible: root.renamingPath === folderItem.path
              width: parent.width
              text: folderItem.path
              font.pixelSize: Style.font.bodySmall
              onVisibleChanged: {
                if (!visible) return
                text = folderItem.path
                Qt.callLater(function() {
                  renameField.forceActiveFocus()
                  renameField.selectAll()
                })
              }
              onAccepted: {
                var value = String(text || "").trim()
                if (value && value !== folderItem.path) root.renameFolderRequested(folderItem.path, value)
                root.renamingPath = ""
              }
              Keys.onEscapePressed: function(event) {
                root.renamingPath = ""
                event.accepted = true
              }
            }

            BorderSurface {
              id: folderRow
              visible: root.renamingPath !== folderItem.path
              anchors.fill: parent
              color: folderItem.dropActive
                ? Util.alpha(Commons.Color.accent, 0.18)
                : root.category === "folder:" + folderItem.path
                  ? Style.selectedAccentFill
                  : folderMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
              borderSpec: root.category === "folder:" + folderItem.path
                ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
                : Border.none
              radius: Style.cornerRadius

              Rectangle {
                visible: root.category === "folder:" + folderItem.path
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.space(3)
                color: Commons.Color.accent
              }

              Item {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8) + root.folderDepth(folderItem.path) * Style.space(10)
                anchors.rightMargin: Style.space(6)

                Text {
                  width: parent.width - (folderActions.visible ? folderActions.width + Style.space(6) : 0)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.folderLeaf(folderItem.path)
                  textFormat: Text.PlainText
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.category === "folder:" + folderItem.path
                  elide: Text.ElideRight
                }

                Row {
                  id: folderActions
                  visible: folderMouse.containsMouse || folderMouse.containsPress
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  Text {
                    text: "✎"
                    color: editMouse.containsMouse ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    MouseArea {
                      id: editMouse
                      anchors.fill: parent
                      anchors.margins: -3
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.beginRename(folderItem.path)
                    }
                  }
                  Text {
                    text: "×"
                    color: deleteMouse.containsMouse ? Commons.Color.urgent : Util.alpha(Commons.Color.foreground, 0.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    MouseArea {
                      id: deleteMouse
                      anchors.fill: parent
                      anchors.margins: -3
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.deleteFolderRequested(folderItem.path)
                    }
                  }
                }
              }

              MouseArea {
                id: folderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.categorySelected("folder:" + folderItem.path)
              }

              DropArea {
                id: folderDrop
                anchors.fill: parent
                keys: ["text/x-quill-note"]
                onEntered: function(drag) {
                  folderItem.dropActive = true
                  drag.accept(Qt.MoveAction)
                }
                onExited: folderItem.dropActive = false
                onDropped: function(drop) {
                  folderItem.dropActive = false
                  var payload = String(drop.text || "")
                  if (payload === "" && drop.getDataAsString) {
                    payload = String(drop.getDataAsString("text/x-quill-note") || "")
                  }
                  if (payload !== "") root.noteDropRequested(payload, folderItem.path)
                  drop.accept(Qt.MoveAction)
                }
              }
            }
          }
        }
      }
    }

    SideRow {
      id: trashRow
      label: "Trash"
      count: root.trashCount
      selected: root.category === "trash"
      onActivated: root.categorySelected("trash")
    }
  }

  // Rename/delete for one real tag. Pure parent rows have no menu.
  Menu {
    id: tagMenu
    objectName: "tagMenu"
    parent: Overlay.overlay
    width: Style.space(200)
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
      objectName: "tagMenuRename"
      text: "Rename or merge…"
      onTriggered: root.tagActionRequested(root.tagMenuTag, "rename")
    }
    ContextMenuItem {
      objectName: "tagMenuDelete"
      text: "Delete tag…"
      onTriggered: root.tagActionRequested(root.tagMenuTag, "delete")
    }
  }

  component SideRow: BorderSurface {
    id: sideRow

    property string label: ""
    property int count: 0
    property bool showCount: true
    property bool selected: false
    property int indent: 0
    property bool rowFocus: false
    // A small hover-only action (× on saved searches, ⋯ on tags). It is a
    // sibling of the row MouseArea, never inside it, so the action keeps its
    // own click.
    property string actionText: ""
    property color actionColor: Commons.Color.urgent
    readonly property bool hovered: rowMouse.containsMouse || actionMouse.containsMouse
    // Inbox opts into being a drop target; other SideRows leave this off.
    property bool dropEnabled: false
    property string dropFolder: ""
    property bool dropActive: false
    signal activated()
    signal actionTriggered()
    signal rightClicked()
    signal dropRequested(string payload, string folder)

    width: parent ? parent.width : Style.space(160)
    height: Style.space(30)
    color: dropActive
      ? Util.alpha(Commons.Color.accent, 0.18)
      : selected
        ? Style.selectedAccentFill
        : hovered ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
    borderSpec: selected ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent) : Border.none
    radius: Style.cornerRadius

    Rectangle {
      visible: sideRow.selected
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(3)
      color: Commons.Color.accent
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8) + sideRow.indent
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(6)

      Text {
        id: sideLabel
        width: parent.width - (sideCount.visible ? sideCount.width + parent.spacing : 0)
          - (sideAction.visible ? sideAction.width + parent.spacing : 0)
        anchors.verticalCenter: parent.verticalCenter
        text: sideRow.label
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: sideRow.selected
        elide: Text.ElideRight
      }
      Text {
        id: sideCount
        visible: sideRow.showCount
        anchors.verticalCenter: parent.verticalCenter
        text: String(sideRow.count)
        color: Util.alpha(Commons.Color.foreground, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) sideRow.rightClicked()
        else sideRow.activated()
      }
    }

    Text {
      id: sideAction
      visible: sideRow.actionText !== "" && (rowMouse.containsMouse || actionMouse.containsMouse)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: sideRow.actionText
      color: actionMouse.containsMouse ? sideRow.actionColor : Util.alpha(Commons.Color.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.body

      MouseArea {
        id: actionMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sideRow.actionTriggered()
      }
    }

    DropArea {
      id: sideDrop
      anchors.fill: parent
      visible: sideRow.dropEnabled
      enabled: sideRow.dropEnabled
      keys: ["text/x-quill-note"]
      onEntered: function(drag) {
        if (!sideRow.dropEnabled) return
        sideRow.dropActive = true
        drag.accept(Qt.MoveAction)
      }
      onExited: sideRow.dropActive = false
      onDropped: function(drop) {
        sideRow.dropActive = false
        if (!sideRow.dropEnabled) return
        var payload = String(drop.text || "")
        if (payload === "" && drop.getDataAsString) {
          payload = String(drop.getDataAsString("text/x-quill-note") || "")
        }
        if (payload !== "") sideRow.dropRequested(payload, sideRow.dropFolder)
        drop.accept(Qt.MoveAction)
      }
    }
  }
}
