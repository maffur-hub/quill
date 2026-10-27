import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Left library rail: saved views, tag counts and the folder tree.
BorderSurface {
  id: root

  property var notes: []
  property var folders: []
  property var tags: []
  property string category: "all"
  property int trashCount: 0

  signal categorySelected(string category)
  signal createFolderRequested(string path)
  signal renameFolderRequested(string path, string next)
  signal deleteFolderRequested(string path)
  signal collapseRequested()

  property string renamingPath: ""
  property bool creatingFolder: false

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
          model: root.tags
          delegate: SideRow {
            required property var modelData
            label: "#" + String(modelData.tag)
            count: Number(modelData.count)
            indent: 4
            selected: root.category === "tag:" + String(modelData.tag)
            onActivated: root.categorySelected("tag:" + String(modelData.tag))
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
          onActivated: root.categorySelected("folder:")
        }

        Repeater {
          model: root.folders
          delegate: Item {
            id: folderItem
            required property var modelData
            readonly property string path: String(modelData)
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
              color: root.category === "folder:" + folderItem.path
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

  component SideRow: BorderSurface {
    id: sideRow

    property string label: ""
    property int count: 0
    property bool selected: false
    property int indent: 0
    property bool rowFocus: false
    signal activated()

    width: parent ? parent.width : Style.space(160)
    height: Style.space(30)
    color: selected
      ? Style.selectedAccentFill
      : rowMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
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
        width: parent.width - sideCount.width - parent.spacing
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
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: sideRow.activated()
    }
  }
}
