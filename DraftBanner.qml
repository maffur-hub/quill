import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Recovery prompt for an adjacent crash draft. The library/detached window
// shows it instead of a hidden autosave: the stored note is visible and the
// editor stays disabled until the user chooses a side.
BorderSurface {
  id: root

  property int draftModified: 0

  signal recoverRequested()
  signal discardRequested()

  objectName: "draftBanner"
  implicitHeight: Style.space(40)
  height: implicitHeight
  color: Util.alpha(Commons.Color.accent, 0.10)
  borderSpec: Border.controlSpec("normal", Commons.Color.accent, Commons.Color.accent)
  radius: Style.cornerRadius

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(6)

    Text {
      id: message
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - actions.width - Style.space(8))
      text: root.draftModified > 0
        ? "Unsaved draft from " + Qt.formatDateTime(new Date(root.draftModified), "MMM d, HH:mm")
        : "Unsaved draft"
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Button {
        objectName: "draftRecoverButton"
        text: "Recover"
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(3)
        onClicked: root.recoverRequested()
      }

      Button {
        objectName: "draftDiscardButton"
        text: "Discard"
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(3)
        onClicked: root.discardRequested()
      }
    }
  }
}
