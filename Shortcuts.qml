import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Keyboard cheat sheet, opened with `?` or F1 from the library.
//
// The rows live here rather than only in the README so the sheet and the
// component cannot drift; the README keeps the same table for people who read
// it on GitHub. The host owns the popup's parent and decides when it opens, so
// it is re-anchored before every open (Qt drops a closed popup's parent).
Popup {
  id: root
  objectName: "shortcutsPopup"

  readonly property var groups: [
    {
      title: "Notes",
      rows: [
        { keys: "Ctrl+N", action: "New note" },
        { keys: "Ctrl+Shift+N", action: "New note from a template" },
        { keys: "Ctrl+Shift+Delete", action: "Move to Trash (press twice)" },
        { keys: "Ctrl+Shift+P", action: "Pin or unpin" },
        { keys: "Ctrl+Shift+T", action: "Add or remove tags" },
        { keys: "Ctrl+Return", action: "Open in a detached window" },
        { keys: "Ctrl+Shift+Enter", action: "Open the library in its own window" }
      ]
    },
    {
      title: "Find",
      rows: [
        { keys: "Ctrl+P", action: "Quick switcher" },
        { keys: "Ctrl+F", action: "Search" },
        { keys: "/", action: "Search, when nothing else has focus" },
        { keys: "Ctrl+Shift+F", action: "Advanced search filters" }
      ]
    },
    {
      title: "Editor",
      rows: [
        { keys: "Ctrl+B / Ctrl+I", action: "Bold / italic" },
        { keys: "Ctrl+U / Ctrl+Shift+X", action: "Underline / strikethrough" },
        { keys: "Ctrl+Shift+H / K", action: "Highlight / link to a note" },
        { keys: "Ctrl+K", action: "Link" },
        { keys: "Ctrl+Z / Ctrl+Shift+Z", action: "Undo / redo (Ctrl+Y also redoes)" },
        { keys: "Tab / Shift+Tab", action: "Indent or outdent the selected lines" },
        { keys: "Ctrl+T", action: "Edit the table under the caret" },
        { keys: "Ctrl+E", action: "Cycle edit / split / preview" },
        { keys: "Ctrl+S", action: "Save now" }
      ]
    },
    {
      title: "Focus and windows",
      rows: [
        { keys: "Ctrl+1 / Ctrl+2 / Ctrl+3", action: "Sidebar / list / editor" },
        { keys: "Esc", action: "Clear the search, then close" },
        { keys: "?", action: "This sheet" }
      ]
    }
  ]

  parent: Overlay.overlay
  anchors.centerIn: Overlay.overlay
  width: Math.max(Style.space(360),
    Math.min(Style.space(560), (parent ? parent.width : Style.space(600)) - Style.space(40)))
  height: Math.max(Style.space(280),
    Math.min(Style.space(540), (parent ? parent.height : Style.space(600)) - Style.space(40)))
  padding: Style.space(12)
  modal: true
  dim: true
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

  onClosed: sheet.forceActiveFocus()

  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  function openSheet() {
    root.open()
    sheet.forceActiveFocus()
  }

  component KeyRow: Row {
    id: keyRow

    required property var modelData

    width: sheet.width
    spacing: Style.space(10)

    readonly property real keyWidth: Math.min(Style.space(190), Math.max(0, width * 0.42))

    Text {
      width: keyRow.keyWidth
      text: String(keyRow.modelData.keys)
      textFormat: Text.PlainText
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      width: Math.max(0, keyRow.width - keyRow.keyWidth - keyRow.spacing)
      text: String(keyRow.modelData.action)
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.78)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Item {
    id: sheet
    anchors.fill: parent
    focus: true

    Flickable {
      id: sheetScroll
      anchors.fill: parent
      clip: true
      contentHeight: sheetColumn.height
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: sheetColumn
        width: sheetScroll.width
        spacing: Style.space(4)

        Repeater {
          model: root.groups

          delegate: Column {
            id: group
            required property var modelData

            width: sheetColumn.width
            spacing: Style.space(2)

            Text {
              topPadding: Style.space(6)
              text: String(group.modelData.title)
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Repeater {
              model: group.modelData.rows

              delegate: KeyRow {}
            }
          }
        }
      }
    }
  }
}
