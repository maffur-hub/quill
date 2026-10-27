import QtQuick
import Quickshell
import Quickshell.Io

// QML side of the chat bridge.
//
// The long-lived scripts/quill-agent child owns HTTP and SSE; this item only
// writes JSONL commands and folds the events into one ListModel (plus a small
// amount of connection state). Keeping a single model here means ChatDock can
// update a text role in place during a stream instead of rebuilding the whole
// transcript on every delta.
Item {
  id: root

  property string pluginDir: ""
  property string dataRoot: ""

  property bool ready: false
  property bool busy: false
  property string error: ""
  property string notice: ""
  property var sessions: []
  property string activeSessionID: ""
  property string activeTitle: ""
  property string agentName: "Build"
  property var usage: ({ cost: 0, tokens: null })
  property var permission: null
  property string lastStderr: ""

  // Model roles: kind (user|assistant), messageID, text, reasoning, toolsJson,
  // time. Tool rows are a JSON string because ListModel's dynamic roles cannot
  // carry a JS array; ChatMessage parses it into {toolID,name,input,status,
  // output,error} objects.
  property alias messages: messageModel

  signal sessionsUpdated()
  signal historyLoaded()

  property bool quitting: false
  property bool started: false
  property bool relaunchWhenStopped: false
  readonly property bool bridgeRunning: process.running
  readonly property int bridgePid: process.processId || 0
  property string pendingText: ""
  property string lastUserMessageID: ""
  property int localMessageSeq: 0

  function writeLine(object) {
    if (!process.running) return false
    try {
      process.write(JSON.stringify(object) + "\n")
      return true
    } catch (error) {
      root.error = "Could not write to the chat bridge"
      return false
    }
  }

  function start() {
    started = true
    // Reuse a live bridge. Sending start again would reconnect SSE and reset
    // the bridge's transcript bookkeeping for an already-open dock.
    if (process.running) {
      if (quitting) relaunchWhenStopped = true
      return
    }
    relaunchWhenStopped = false
    stopTimer.stop()
    quitting = false
    error = ""
    ready = false
    delayedStart.restart()
  }

  function retry() {
    error = ""
    notice = ""
    if (process.running && ready) {
      writeLine({ type: "start", dataRoot: dataRoot })
      return
    }
    if (process.running) process.running = false
    stopTimer.stop()
    quitting = false
    ready = false
    delayedStart.restart()
  }

  function refreshSessions() {
    writeLine({ type: "sessions" })
  }

  function newChat(title) {
    var command = { type: "new" }
    if (title) command.title = String(title)
    writeLine(command)
  }

  function openSession(sessionID) {
    if (!sessionID) return
    writeLine({ type: "open", sessionID: String(sessionID) })
  }

  function sendPrompt(text) {
    var value = String(text || "").trim()
    if (!value || busy) return
    if (!activeSessionID) {
      // Creating a session is asynchronous; send as soon as `opened` lands.
      pendingText = value
      newChat()
      return
    }
    appendUser(value)
    busy = true
    writeLine({ type: "prompt", sessionID: activeSessionID, text: value })
  }

  function interrupt() {
    if (!activeSessionID) return
    writeLine({ type: "interrupt", sessionID: activeSessionID })
  }

  function renameSession(sessionID, title) {
    if (!sessionID) return
    writeLine({ type: "rename", sessionID: String(sessionID), title: String(title || "") })
    if (String(sessionID) === activeSessionID) activeTitle = String(title || "")
  }

  function deleteSession(sessionID) {
    if (!sessionID) return
    if (String(sessionID) === activeSessionID) {
      // The bridge confirms with an empty history, but clearing here keeps the
      // dock from showing the deleted transcript while the DELETE is in
      // flight.
      activeSessionID = ""
      activeTitle = ""
      busy = false
      permission = null
      messageModel.clear()
    }
    writeLine({ type: "delete", sessionID: String(sessionID) })
  }

  function sendContext(context) {
    if (!ready || !dataRoot) return
    writeLine({ type: "context", context: context || ({}) })
  }

  function replyPermission(reply) {
    if (!permission) return
    writeLine({
      type: "reply",
      sessionID: String(permission.sessionID || ""),
      requestID: String(permission.requestID || ""),
      reply: String(reply || "reject")
    })
    permission = null
  }

  function stop() {
    quitting = true
    relaunchWhenStopped = false
    if (process.running) writeLine({ type: "stop" })
    // Closing stdin also makes the bridge exit; this covers a hung child.
    stopTimer.restart()
  }

  // --------------------------------------------------------------- transcript
  function appendUser(text) {
    localMessageSeq += 1
    lastUserMessageID = "local-" + localMessageSeq
    messageModel.append({
      kind: "user",
      messageID: lastUserMessageID,
      text: String(text),
      reasoning: "",
      toolsJson: "[]",
      time: Date.now()
    })
    scrollRequested()
  }

  // A rejected prompt (for example 409 while the previous run is still
  // answering) must not leave an optimistic bubble that the service never
  // received. Only the last local prompt can still be pending here.
  function removePendingUser() {
    if (lastUserMessageID === "") return
    var index = findMessage(lastUserMessageID)
    if (index >= 0 && index === messageModel.count - 1) messageModel.remove(index)
    lastUserMessageID = ""
  }

  // Exposed so ChatDock can ask for a scroll after it has appended locally.
  signal scrollRequested()

  function findMessage(messageID) {
    var key = String(messageID || "")
    for (var i = messageModel.count - 1; i >= 0; i--) {
      if (String(messageModel.get(i).messageID) === key) return i
    }
    return -1
  }

  function ensureAssistant(messageID) {
    var index = findMessage(messageID)
    if (index >= 0) return index
    messageModel.append({
      kind: "assistant",
      messageID: String(messageID || ""),
      text: "",
      reasoning: "",
      toolsJson: "[]",
      time: Date.now()
    })
    return messageModel.count - 1
  }

  function appendDelta(messageID, kind, delta) {
    var index = ensureAssistant(messageID)
    var role = kind === "reasoning" ? "reasoning" : "text"
    var current = String(messageModel.get(index)[role] || "")
    messageModel.setProperty(index, role, current + String(delta || ""))
  }

  function setMessageText(messageID, kind, text) {
    var index = ensureAssistant(messageID)
    var role = kind === "reasoning" ? "reasoning" : "text"
    messageModel.setProperty(index, role, String(text || ""))
  }

  function updateTool(messageID, event) {
    var index = ensureAssistant(messageID)
    var existing = []
    try {
      existing = JSON.parse(String(messageModel.get(index).toolsJson || "[]"))
    } catch (error) {
      existing = []
    }
    if (!Array.isArray(existing)) existing = []
    var tools = []
    for (var i = 0; i < existing.length; i++) tools.push(existing[i])
    var found = -1
    for (var t = 0; t < tools.length; t++) {
      if (String(tools[t].toolID) === String(event.toolID)) { found = t; break }
    }
    if (found < 0) {
      tools.push({
        toolID: String(event.toolID || ""),
        name: String(event.name || "tool"),
        input: event.input === undefined ? null : event.input,
        status: String(event.status || "running"),
        output: String(event.output || ""),
        error: String(event.error || "")
      })
    } else {
      var entry = tools[found]
      // A later event may omit the input or a specific name; keep what we
      // already know rather than blanking the row.
      tools[found] = {
        toolID: entry.toolID,
        name: String(event.name || entry.name || "tool"),
        input: event.input === undefined || event.input === null ? entry.input : event.input,
        status: String(event.status || entry.status || "running"),
        output: event.output !== undefined && event.output !== "" ? String(event.output) : entry.output,
        error: event.error !== undefined && event.error !== "" ? String(event.error) : entry.error
      }
    }
    messageModel.setProperty(index, "toolsJson", JSON.stringify(tools))
  }

  function rebuildHistory(items) {
    lastUserMessageID = ""
    messageModel.clear()
    var list = Array.isArray(items) ? items : []
    for (var i = 0; i < list.length; i++) {
      var item = list[i] || ({})
      if (item.kind !== "user" && item.kind !== "assistant") continue
      messageModel.append({
        kind: item.kind,
        messageID: String(item.id || ""),
        text: String(item.text || ""),
        reasoning: String(item.reasoning || ""),
        toolsJson: JSON.stringify(Array.isArray(item.tools) ? item.tools : []),
        time: Number(item.time || 0)
      })
    }
  }

  function titleFor(sessionID) {
    for (var i = 0; i < sessions.length; i++) {
      if (String(sessions[i].id) === String(sessionID)) return String(sessions[i].title || "")
    }
    return ""
  }

  // ------------------------------------------------------------------- events
  function handleLine(line) {
    var event = null
    try {
      event = JSON.parse(String(line || ""))
    } catch (error) {
      return
    }
    if (!event || !event.type) return
    var type = String(event.type)

    if (type === "ready") {
      ready = true
      error = ""
      if (event.agent) agentName = capitalise(String(event.agent))
      return
    }
    if (type === "error") {
      var message = String(event.message || "Chat failed")
      if (event.scope === "service") {
        error = message
      } else if (event.scope === "prompt") {
        notice = message
        busy = false
        removePendingUser()
      } else {
        notice = message
        if (event.scope === "session") busy = false
      }
      return
    }
    if (type === "sessions") {
      sessions = Array.isArray(event.items) ? event.items : []
      if (error !== "") error = ""
      if (activeSessionID) {
        var fresh = titleFor(activeSessionID)
        if (fresh !== "") activeTitle = fresh
      }
      sessionsUpdated()
      return
    }
    if (type === "opened") {
      activeSessionID = String(event.sessionID || "")
      activeTitle = String(event.title || "")
      if (event.agent) agentName = capitalise(String(event.agent))
      notice = ""
      sessionsUpdated()
      if (pendingText !== "" && activeSessionID !== "") {
        var queued = pendingText
        pendingText = ""
        Qt.callLater(function() { root.sendPrompt(queued) })
      }
      return
    }
    if (type === "history") {
      if (String(event.sessionID === undefined ? "" : event.sessionID) !== activeSessionID) return
      if (event.title !== undefined && String(event.title) !== "") activeTitle = String(event.title)
      rebuildHistory(event.messages)
      historyLoaded()
      return
    }
    if (type === "delta") {
      if (String(event.sessionID || "") !== activeSessionID) return
      appendDelta(String(event.messageID || ""), String(event.kind || "text"), event.delta)
      return
    }
    if (type === "text") {
      if (String(event.sessionID || "") !== activeSessionID) return
      setMessageText(String(event.messageID || ""),
        String(event.kind || "text"), event.text)
      return
    }
    if (type === "tool") {
      if (String(event.sessionID || "") !== activeSessionID) return
      updateTool(String(event.messageID || ""), event)
      return
    }
    if (type === "status") {
      if (String(event.sessionID || "") !== activeSessionID) return
      busy = String(event.status) === "running"
      if (!busy) notice = ""
      return
    }
    if (type === "usage") {
      if (String(event.sessionID || "") !== activeSessionID) return
      usage = { cost: Number(event.cost || 0), tokens: event.tokens }
      return
    }
    if (type === "permission") {
      if (String(event.sessionID || "") !== activeSessionID) return
      permission = event
      return
    }
    if (type === "permission-cleared") {
      if (permission && String(permission.requestID || "") === String(event.requestID || "")) {
        permission = null
      }
      return
    }
  }

  function capitalise(value) {
    var text = String(value || "")
    return text.length === 0 ? text : text.charAt(0).toUpperCase() + text.slice(1)
  }

  onDataRootChanged: {
    if (process.running && ready) writeLine({ type: "start", dataRoot: dataRoot })
  }

  Timer {
    id: delayedStart
    interval: 250
    onTriggered: {
      if (root.quitting || process.running) return
      root.lastStderr = ""
      root.error = ""
      process.command = ["node", String(root.pluginDir) + "/scripts/quill-agent"]
      process.running = true
    }
  }

  Timer {
    id: stopTimer
    interval: 600
    onTriggered: if (process.running) process.running = false
  }

  ListModel {
    id: messageModel
  }

  Process {
    id: process
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text !== "") root.lastStderr = text
      }
    }
    onStarted: root.writeLine({ type: "start", dataRoot: root.dataRoot })
    onExited: function(exitCode) {
      root.ready = false
      root.busy = false
      if (root.relaunchWhenStopped) {
        // The dock was reopened while the previous child was still stopping.
        // Start exactly one replacement after it has gone.
        root.relaunchWhenStopped = false
        root.quitting = false
        stopTimer.stop()
        delayedStart.restart()
        return
      }
      if (root.quitting) return
      root.error = root.lastStderr !== ""
        ? root.lastStderr
        : "Chat bridge stopped unexpectedly"
    }
  }

  Component.onDestruction: {
    quitting = true
    if (process.running) process.running = false
  }
}
