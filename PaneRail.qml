import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Slim placeholder for a collapsed left pane. One chevron brings the pane
// back; the vertical label keeps the rail identifiable without stealing width.
BorderSurface {
  id: root

  property string label: ""

  signal expandRequested()

  color: Util.alpha(Commons.Color.foreground, 0.012)
  borderSpec: Border.flat(Util.alpha(Commons.Color.foreground, 0.1), 1)
  radius: Style.cornerRadius

  Button {
    id: expandButton
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.topMargin: Style.space(4)
    width: Style.space(18)
    height: Style.space(18)
    text: ""
    iconText: "›"
    iconSize: Style.font.bodySmall
    horizontalPadding: 0
    verticalPadding: 0
    tooltipText: "Show " + root.label.toLowerCase()
    onClicked: root.expandRequested()
  }

  Text {
    anchors.centerIn: parent
    width: Style.space(96)
    horizontalAlignment: Text.AlignHCenter
    text: root.label.toUpperCase()
    rotation: -90
    transformOrigin: Item.Center
    color: Util.alpha(Commons.Color.foreground, 0.3)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
