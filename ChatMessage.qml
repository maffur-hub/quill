import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MathSyntax.js" as MathSyntax
import "MathText.js" as MathText

// One chat transcript row. User prompts sit in a tinted bubble on the right;
// assistant answers sit plain on the pane so Markdown, maths and tool rows
// read like the note preview. The dock owns the transcript model and the
// shared MathService, so this file only renders and requests what it needs.
Item {
  id: root

  required property string kind
  required property string messageID
  required property string text
  required property string reasoning
  required property string toolsJson
  required property real time

  property var dock: null
  property var expandedTools: ({})
  property int expansionRev: 0
  property bool reasoningOpen: false

  readonly property bool isUser: kind === "user"
  readonly property var displayLines: String(text || "").split("\n")
  readonly property bool hasDisplayMath: !isUser && MathSyntax.findDisplayBlocks(displayLines).length > 0
  readonly property bool richText: !isUser
    && (MathSyntax.hasInlineMath(String(text || "")) || hasDisplayMath
      || MathText.hasFormatting(String(text || "")))

  readonly property var toolList: {
    try {
      var parsed = JSON.parse(String(toolsJson || "[]"))
      return Array.isArray(parsed) ? parsed : []
    } catch (error) {
      return []
    }
  }

  readonly property string renderedText: {
    if (!richText) return String(text || "")
    // revision is the dependency: an SVG arriving rebuilds the HTML.
    var revision = dock ? dock.mathRevision : 0
    return MathText.toHtml(String(text || ""), function(tex, display) {
      return dock ? dock.mathResolver(tex, display) : null
    }, MathSyntax)
  }

  width: ListView.view ? ListView.view.width : implicitWidth
  implicitHeight: isUser ? userBubble.height + Style.space(2) : assistantColumn.height
  height: implicitHeight

  function requestMath() {
    if (!dock || !richText) return
    var spans = MathSyntax.inlineSpans(String(text || ""))
    for (var i = 0; i < spans.length; i++) dock.mathRequest(spans[i].tex, false)
    var blocks = MathSyntax.findDisplayBlocks(displayLines)
    for (var b = 0; b < blocks.length; b++) dock.mathRequest(blocks[b].tex, true)
  }

  function toolExpanded(toolID) {
    var revision = expansionRev
    return expandedTools[String(toolID)] === true
  }

  function toggleTool(toolID) {
    var next = {}
    for (var key in expandedTools) next[key] = expandedTools[key]
    next[String(toolID)] = !(next[String(toolID)] === true)
    expandedTools = next
    expansionRev += 1
  }

  function toolCommand(input) {
    if (input === undefined || input === null) return ""
    if (typeof input === "string") return input
    if (typeof input === "object") {
      var keys = ["command", "cmd", "pattern", "path", "file", "url", "query"]
      for (var i = 0; i < keys.length; i++) {
        if (input[keys[i]] !== undefined && input[keys[i]] !== null) return String(input[keys[i]])
      }
    }
    return ""
  }

  function toolLabel(name, input) {
    var lower = String(name || "").toLowerCase()
    var command = toolCommand(input)
    if (command !== "") return command.replace(/\s+/g, " ").trim()
    if (lower === "read" || lower === "read_file") return "Read a note"
    if (lower === "grep" || lower === "search") return "Search notes"
    if (lower === "glob") return "Find notes"
    if (lower === "edit" || lower === "write" || lower === "patch") return "Edit a note"
    if (lower === "webfetch" || lower === "fetch") return "Fetch a page"
    if (lower === "shell" || lower === "bash") return "Run a command"
    if (lower === "execute" || lower === "tool") return "Run a tool"
    var text = String(name || "Tool")
    return text.charAt(0).toUpperCase() + text.slice(1)
  }

  onTextChanged: if (richText) mathDebounce.restart()
  Component.onCompleted: if (richText) Qt.callLater(requestMath)

  Timer {
    id: mathDebounce
    interval: 120
    onTriggered: root.requestMath()
  }

  // ------------------------------------------------------------- user bubble
  BorderSurface {
    id: userBubble
    visible: root.isUser
    anchors.right: parent.right
    width: Math.min(root.width * 0.88, userLabel.implicitWidth + Style.space(20))
    height: userLabel.implicitHeight + Style.space(14)
    color: Util.alpha(Commons.Color.accent, 0.09)
    borderSpec: Border.flat(Util.alpha(Commons.Color.accent, 0.2), 1)
    radius: Style.cornerRadius

    Text {
      id: userLabel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      text: root.text
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      lineHeight: 1.2
      wrapMode: Text.Wrap
    }
  }

  // -------------------------------------------------------- assistant column
  Column {
    id: assistantColumn
    visible: !root.isUser
    width: root.width
    spacing: Style.space(6)

    // Reasoning stays collapsed as a dim row; it is useful when a long answer
    // is still forming, but it should not dominate the transcript.
    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: String(root.reasoning || "") !== ""

      Item {
        width: parent.width
        height: Style.space(18)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: (root.reasoningOpen ? "▾  " : "▸  ") + "Thinking"
          color: Util.alpha(Commons.Color.foreground, 0.42)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.reasoningOpen = !root.reasoningOpen
        }
      }

      Text {
        visible: root.reasoningOpen
        width: parent.width
        text: String(root.reasoning || "")
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.italic: true
        lineHeight: 1.2
        wrapMode: Text.Wrap
        }
    }

    Repeater {
      model: root.toolList

      delegate: Column {
        id: toolRow

        readonly property var tool: modelData || ({})
        readonly property string toolID: String(tool.toolID || "")
        readonly property string toolName: String(tool.name || "tool")
        readonly property string status: String(tool.status || "running")
        readonly property string output: String(tool.output || "")
        readonly property string failure: String(tool.error || "")
        readonly property bool expanded: root.toolExpanded(toolID)
        readonly property bool running: status === "running"

        width: assistantColumn.width
        spacing: Style.space(3)

        Item {
          id: toolHeader
          width: parent.width
          height: Style.space(20)

          Row {
            anchors.fill: parent
            spacing: Style.space(6)

            Rectangle {
              id: statusDot
              width: Style.space(6)
              height: width
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: toolRow.status === "error" ? Commons.Color.urgent
                : toolRow.running ? Commons.Color.accent
                : Util.alpha(Commons.Color.foreground, 0.32)

              SequentialAnimation on opacity {
                running: toolRow.running
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 550 }
                NumberAnimation { to: 1; duration: 550 }
              }
            }

            Text {
              width: Math.max(0, parent.width - Style.space(30))
              anchors.verticalCenter: parent.verticalCenter
              text: (root.toolExpanded(toolRow.toolID) ? "▾  " : "▸  ")
                + root.toolLabel(toolRow.toolName, toolRow.tool.input)
              textFormat: Text.PlainText
              color: toolRow.status === "error"
                ? Commons.Color.urgent
                : Util.alpha(Commons.Color.foreground, toolRow.running ? 0.78 : 0.58)
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: (toolRow.output !== "" || toolRow.failure !== "") ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (toolRow.output !== "" || toolRow.failure !== "") root.toggleTool(toolRow.toolID)
            }
          }
        }

        BorderSurface {
          visible: toolRow.expanded && (toolRow.output !== "" || toolRow.failure !== "")
          width: parent.width
          height: Math.min(Style.space(220), toolOutput.implicitHeight + Style.space(12))
          color: Util.alpha(Commons.Color.foreground, 0.035)
          borderSpec: Border.flat(Util.alpha(Commons.Color.foreground, 0.12), 1)
          radius: Style.cornerRadius
          clip: true

          Flickable {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            clip: true
            contentWidth: width
            contentHeight: toolOutput.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Text {
              id: toolOutput
              width: parent.width
              text: toolRow.failure !== "" ? toolRow.failure : toolRow.output
              textFormat: Text.PlainText
              color: toolRow.failure !== ""
                ? Commons.Color.urgent
                : Util.alpha(Commons.Color.foreground, 0.72)
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              lineHeight: 1.15
              wrapMode: Text.WrapAnywhere
                    }
          }
        }
      }
    }

    Text {
      visible: String(root.text || "") !== ""
      width: parent.width
      text: root.renderedText
      textFormat: root.richText ? Text.RichText : Text.MarkdownText
      wrapMode: Text.Wrap
      color: Commons.Color.foreground
      linkColor: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      lineHeight: 1.15
      onLinkActivated: function(link) {
        if (root.dock) root.dock.linkActivated(link)
      }
    }
  }
}
