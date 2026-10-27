import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// One row in Quill's themed menus.
//
// Qt's Basic Menu delegate is a plain MenuItem with a light background; styling
// the declared items keeps Qt's hover, keyboard and triggered behaviour while
// matching the rest of the shell. The menu itself stays a normal Menu.
MenuItem {
  id: row

  implicitHeight: Style.spacing.popupRowHeight
  leftPadding: Style.spacing.controlPaddingX
  rightPadding: Style.spacing.controlPaddingX
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  opacity: enabled ? 1 : 0.4

  contentItem: Text {
    text: row.text
    font: row.font
    color: row.highlighted ? Commons.Color.menu.selectedText : Commons.Color.menu.text
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  background: Rectangle {
    radius: Style.cornerRadius
    color: row.down
      ? Util.alpha(Commons.Color.menu.selectedBackground, 0.16)
      : row.highlighted ? Commons.Color.menu.selectedBackground : "transparent"
    border.width: row.highlighted ? 1 : 0
    border.color: Commons.Color.menu.selectedBorder
  }
}
