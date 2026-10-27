import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Conflict prompt for a note that changed on disk while the buffer was dirty.
// Clean notes reload silently; this banner only appears when applying the
// external text would discard unsaved local edits.
BorderSurface {
  id: root

  signal reloadRequested()
  signal keepRequested()

  objectName: "externalChangeBanner"
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
      text: "This note changed on disk."
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
        objectName: "externalReloadButton"
        text: "Reload"
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(3)
        onClicked: root.reloadRequested()
      }

      Button {
        objectName: "externalKeepButton"
        text: "Keep mine"
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(3)
        onClicked: root.keepRequested()
      }
    }
  }
}
