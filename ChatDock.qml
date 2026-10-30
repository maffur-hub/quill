import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Right-hand chat dock for the library window.
//
// The dock is deliberately chat-only: AgentService owns the bridge and the
// transcript model, PreviewPane's MathService renders formulas, and edits
// still go through the note editor. Opening the dock never moves keyboard
// focus; only clicking the composer or a suggestion does.
Item {
  id: root

  property string dataRoot: ""
  property string pluginDir: ""
  property alias agent: agentService

  signal closeRequested()
  signal linkActivated(string link)

  property bool atBottom: true
  property bool choseInitial: false
  property string armedSessionID: ""
  property bool sendWhenReady: false

  readonly property int mathRevision: mathService.revision
  readonly property bool inputActive: composer.activeFocus

  function mathRequest(tex, display) {
    mathService.request(String(tex === undefined || tex === null ? "" : tex), !!display)
  }

  function mathResolver(tex, display) {
    var entry = mathService.get(String(tex === undefined || tex === null ? "" : tex), !!display)
    if (!entry || !entry.ok) return null
    return { ok: true, path: String(entry.path || "") }
  }

  function scrollToEnd() {
    Qt.callLater(function() {
      if (messageList) messageList.positionViewAtEnd()
    })
  }

  function initialise() {
    if (!visible) return
    if (!agentService.ready) agentService.start()
    if (agentService.ready) {
      agentService.refreshSessions()
      if (agentService.activeSessionID === "") choseInitial = false
    }
  }

  function selectSession(sessionID) {
    if (!sessionID) return
    root.atBottom = true
    agentService.openSession(sessionID)
  }

  function submit() {
    if (agentService.busy) return
    var value = String(composer.text || "").trim()
    if (value === "") return
    if (!agentService.ready || agentService.error !== "") {
      sendWhenReady = true
      agentService.retry()
      return
    }
    sendWhenReady = false
    agentService.sendPrompt(value)
    composer.text = ""
    root.atBottom = true
    scrollToEnd()
  }

  function useSuggestion(label) {
    if (label.indexOf("…") >= 0) {
      composer.text = "Find notes about "
      composer.forceActiveFocus()
      composer.cursorPosition = composer.text.length
      return
    }
    if (!agentService.ready || agentService.error !== "") {
      composer.text = label
      composer.forceActiveFocus()
      composer.cursorPosition = composer.text.length
      return
    }
    agentService.sendPrompt(label)
    root.atBottom = true
    scrollToEnd()
  }

  function requestDelete(sessionID) {
    if (armedSessionID !== sessionID) {
      armedSessionID = sessionID
      armTimer.restart()
      return
    }
    armedSessionID = ""
    armTimer.stop()
    agentService.deleteSession(sessionID)
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

  onVisibleChanged: {
    if (visible) {
      root.atBottom = true
      initialise()
    } else {
      // The dock is closed or the library window went away. Do not leave a
      // bridge (and its SSE connection) alive behind a hidden dock.
      agentService.stop()
    }
  }

  Component.onCompleted: if (visible) Qt.callLater(initialise)

  // One maths process for the whole dock. ChatMessage requests each span it
  // finds; results are cached across messages and the revision retriggers the
  // RichText bindings when an SVG lands.
  MathService {
    id: mathService
  }

  AgentService {
    id: agentService
    pluginDir: root.pluginDir
    dataRoot: root.dataRoot
  }

  Connections {
    target: agentService

    function onReadyChanged() {
      if (!root.visible || !agentService.ready) return
      // A stopped/restarted bridge has no current session; re-open the one the
      // dock still remembers so streaming events are not filtered out.
      if (agentService.activeSessionID !== "") agentService.openSession(agentService.activeSessionID)
      else agentService.refreshSessions()
    }

    function onSessionsUpdated() {
      if (!root.visible || root.choseInitial) return
      root.choseInitial = true
      if (agentService.activeSessionID === "" && agentService.sessions.length > 0) {
        agentService.openSession(agentService.sessions[0].id)
      }
    }

    function onScrollRequested() {
      root.atBottom = true
      root.scrollToEnd()
    }
  }

  // Enter pressed while offline keeps the text in the composer and asks the
  // bridge to reconnect; send it as soon as the service answers.
  Connections {
    target: agentService

    function onReadyChanged() {
      if (agentService.ready && root.sendWhenReady) root.submit()
    }
  }

  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.armedSessionID = ""
  }

  // ------------------------------------------------------------- appearance
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    color: Util.alpha(Commons.Color.foreground, 0.12)
  }

  BorderSurface {
    id: pane
    anchors.fill: parent
    anchors.leftMargin: 1
    color: Util.alpha(Commons.Color.foreground, 0.016)
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  // ------------------------------------------------------------------ header
  Item {
    id: header
    anchors.left: pane.left
    anchors.right: pane.right
    anchors.top: pane.top
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.topMargin: Style.space(9)
    height: Style.space(28)

    Text {
      id: chatTitle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Agent"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      id: agentLabel
      anchors.left: chatTitle.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: agentService.agentName
      color: Util.alpha(Commons.Color.foreground, 0.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      id: closeButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(24)
      height: Style.space(24)
      text: ""
      iconText: "×"
      iconSize: Style.font.body
      horizontalPadding: 0
      verticalPadding: 0
      tooltipText: "Close agent"
      onClicked: root.closeRequested()
    }

    Button {
      id: newButton
      anchors.right: closeButton.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(24)
      height: Style.space(24)
      text: ""
      iconText: "+"
      iconSize: Style.font.body
      horizontalPadding: 0
      verticalPadding: 0
      tooltipText: "New chat"
      onClicked: {
        armTimer.stop()
        armedSessionID = ""
        agentService.newChat()
        root.atBottom = true
      }
    }

    BorderSurface {
      id: sessionPicker
      anchors.left: agentLabel.right
      anchors.leftMargin: Style.space(6)
      anchors.right: newButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(24)
      color: pickerMouse.containsMouse
        ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
        : Util.alpha(Commons.Color.foreground, 0.035)
      borderSpec: Border.flat(Util.alpha(Commons.Color.foreground, 0.12), 1)
      radius: Style.cornerRadius

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.right: pickerChevron.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        text: agentService.activeTitle !== "" ? agentService.activeTitle : "New chat"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.78)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        id: pickerChevron
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "▾"
        color: Util.alpha(Commons.Color.foreground, 0.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: pickerMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sessionPopup.opened ? sessionPopup.close() : sessionPopup.open()
      }
    }
  }

  Rectangle {
    id: headerLine
    anchors.left: pane.left
    anchors.right: pane.right
    anchors.top: header.bottom
    anchors.topMargin: Style.space(7)
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    height: 1
    color: Util.alpha(Commons.Color.foreground, 0.1)
  }

  // -------------------------------------------------------------- transcript
  Item {
    id: messageArea
    anchors.left: pane.left
    anchors.right: pane.right
    anchors.top: headerLine.bottom
    anchors.bottom: bottomBlock.top
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.topMargin: Style.space(8)
    anchors.bottomMargin: Style.space(8)
    clip: true

    ListView {
      id: messageList
      anchors.fill: parent
      visible: agentService.messages.count > 0
      clip: true
      spacing: Style.space(10)
      model: agentService.messages
      boundsBehavior: Flickable.StopAtBounds

      delegate: ChatMessage {
        dock: root
      }

      onMovementStarted: root.atBottom = false
      onMovementEnded: root.atBottom = atYEnd
      onContentHeightChanged: if (root.atBottom) Qt.callLater(positionViewAtEnd)
      onCountChanged: {
        if (root.atBottom) Qt.callLater(positionViewAtEnd)
      }
    }

    // Empty state: three prompts that prove the notes are the primary source
    // without forcing the user to learn the tool surface.
    Column {
      visible: agentService.messages.count === 0
      anchors.centerIn: parent
      width: Math.min(parent.width, Style.space(260))
      spacing: Style.space(8)

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "Ask about your notes"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.8)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.Wrap
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: agentService.ready
          ? "Quill searches the library first, then answers."
          : "Connecting to OpenCode…"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Item { width: 1; height: Style.space(2) }

      Suggestion {
        width: parent.width
        label: "Summarise my recent notes"
        onChosen: root.useSuggestion(label)
      }
      Suggestion {
        width: parent.width
        label: "Find notes about …"
        onChosen: root.useSuggestion(label)
      }
      Suggestion {
        width: parent.width
        label: "What's open right now?"
        onChosen: root.useSuggestion(label)
      }
    }
  }

  // ------------------------------------------------------- permission + input
  Column {
    id: bottomBlock
    anchors.left: pane.left
    anchors.right: pane.right
    anchors.bottom: pane.bottom
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.bottomMargin: Style.space(9)
    spacing: Style.space(6)

    BorderSurface {
      visible: agentService.permission !== null
      width: parent.width
      height: permissionColumn.implicitHeight + Style.space(16)
      color: Util.alpha(Commons.Color.accent, 0.07)
      borderSpec: Border.flat(Util.alpha(Commons.Color.accent, 0.28), 1)
      radius: Style.cornerRadius

      Column {
        id: permissionColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(9)
        spacing: Style.space(5)

        Text {
          width: parent.width
          text: agentService.permission
            ? String(agentService.permission.description || "Permission required")
            : ""
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Text {
          visible: agentService.permission !== null
            && String(agentService.permission.resource || "") !== ""
          width: parent.width
          text: agentService.permission ? String(agentService.permission.resource || "") : ""
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.46)
          font.family: "monospace"
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          spacing: Style.space(5)

          Button {
            text: "Allow once"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            onClicked: agentService.replyPermission("once")
          }
          Button {
            text: "Always"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            onClicked: agentService.replyPermission("always")
          }
          Button {
            text: "Deny"
            foreground: Util.alpha(Commons.Color.foreground, 0.62)
            fontSize: Style.font.caption
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(3)
            onClicked: agentService.replyPermission("reject")
          }
        }
      }
    }

    BorderSurface {
      visible: agentService.error !== ""
      width: parent.width
      height: errorRow.implicitHeight + Style.space(14)
      color: Util.alpha(Commons.Color.urgent, 0.08)
      borderSpec: Border.flat(Util.alpha(Commons.Color.urgent, 0.3), 1)
      radius: Style.cornerRadius

      Row {
        id: errorRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(7)
        spacing: Style.space(6)

        Text {
          width: Math.max(0, parent.width - retryButton.width - parent.spacing)
          anchors.verticalCenter: parent.verticalCenter
          text: agentService.error
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.8)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Button {
          id: retryButton
          anchors.verticalCenter: parent.verticalCenter
          text: "Retry"
          fontSize: Style.font.caption
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: agentService.retry()
        }
      }
    }

    Text {
      visible: agentService.notice !== ""
      width: parent.width
      text: agentService.notice
      textFormat: Text.PlainText
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    BorderSurface {
      width: parent.width
      height: composerRow.implicitHeight + Style.space(12)
      color: Util.alpha(Commons.Color.foreground, 0.028)
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius

      MouseArea {
        anchors.fill: parent
        z: -1
        cursorShape: Qt.IBeamCursor
        onClicked: composer.forceActiveFocus()
      }

      Row {
        id: composerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(7)
        spacing: Style.space(6)

        TextArea {
          id: composer
          width: parent.width - sendButton.width - parent.spacing
          height: Math.min(Style.space(96), Math.max(Style.space(40), contentHeight + Style.space(4)))
          placeholderText: agentService.busy
            ? "Answering…"
            : (agentService.error !== "" || !agentService.ready)
              ? "Offline — press Enter to retry"
              : agentService.activeSessionID === ""
                ? "Ask about your notes…"
                : "Message"
          placeholderTextColor: Util.alpha(Commons.Color.foreground, 0.3)
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          background: null
          leftPadding: 0
          rightPadding: 0
          topPadding: 0
          bottomPadding: 0

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if ((event.modifiers & Qt.ShiftModifier) === 0) {
                event.accepted = true
                root.submit()
              }
            }
          }
        }

        Button {
          id: sendButton
          anchors.verticalCenter: parent.verticalCenter
          text: agentService.busy ? "Stop" : "Send"
          active: !agentService.busy && agentService.ready && agentService.error === ""
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          enabled: agentService.ready && (agentService.busy || agentService.error === "")
          onClicked: {
            if (agentService.busy) agentService.interrupt()
            else root.submit()
          }
        }
      }
    }

    Text {
      width: parent.width
      text: agentService.error !== ""
        ? "Chat is offline"
        : !agentService.ready
          ? "Connecting to OpenCode…"
          : agentService.busy
            ? "Answering…  Stop to interrupt"
            : agentService.activeSessionID === ""
              ? "Enter to start a new chat"
              : "Enter to send  ·  Shift+Enter for a new line"
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.34)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // ----------------------------------------------------------- session picker
  Popup {
    id: sessionPopup
    x: Style.space(8)
    y: Style.space(52)
    width: Math.max(Style.space(220), root.width - Style.space(16))
    implicitHeight: Math.min(Style.space(300),
      sessionList.contentHeight + Style.space(10))
    padding: 1
    focus: true

    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: ListView {
      id: sessionList
      clip: true
      spacing: 1
      model: agentService.sessions
      boundsBehavior: Flickable.StopAtBounds
      implicitHeight: contentHeight

      delegate: BorderSurface {
        id: sessionRow
        required property var modelData
        width: sessionList.width
        height: Style.space(42)
        color: rowMouse.containsMouse
          ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
          : "transparent"
        borderSpec: Border.none
        radius: Style.cornerRadius

        Column {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(9)
          anchors.right: deleteLabel.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1

          Text {
            width: parent.width
            text: String(sessionRow.modelData.title || "New chat")
            textFormat: Text.PlainText
            color: String(sessionRow.modelData.id) === agentService.activeSessionID
              ? Commons.Color.accent
              : Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: String(sessionRow.modelData.id) === agentService.activeSessionID
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: root.relativeTime(sessionRow.modelData.updated)
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, 0.38)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          id: deleteLabel
          anchors.right: parent.right
          anchors.rightMargin: Style.space(9)
          anchors.verticalCenter: parent.verticalCenter
          text: root.armedSessionID === String(sessionRow.modelData.id) ? "Delete?" : "×"
          textFormat: Text.PlainText
          color: root.armedSessionID === String(sessionRow.modelData.id)
            ? Commons.Color.urgent
            : Util.alpha(Commons.Color.foreground, 0.34)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          anchors.rightMargin: Style.space(38)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            sessionPopup.close()
            root.selectSession(String(sessionRow.modelData.id))
          }
        }

        MouseArea {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(36)
          cursorShape: Qt.PointingHandCursor
          z: 2
          onClicked: root.requestDelete(String(sessionRow.modelData.id))
        }
      }

      Text {
        visible: agentService.sessions.length === 0
        anchors.centerIn: parent
        text: "No chats yet"
        color: Util.alpha(Commons.Color.foreground, 0.36)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // -------------------------------------------------------------- small parts
  component Suggestion: BorderSurface {
    id: suggestion

    property string label: ""
    signal chosen()

    height: Style.space(28)
    color: suggestionMouse.containsMouse
      ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
      : Util.alpha(Commons.Color.foreground, 0.03)
    borderSpec: Border.flat(Util.alpha(Commons.Color.foreground, 0.1), 1)
    radius: Style.cornerRadius

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      text: suggestion.label
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.68)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    MouseArea {
      id: suggestionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: suggestion.chosen()
    }
  }
}
