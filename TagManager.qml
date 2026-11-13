import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Rename/delete confirmation for one real tag.
//
// The caller owns the backend write: this popup only collects and validates a
// name, then emits commitRequested(). Renaming onto a tag that already exists
// merges in the store, so the view warns before the user commits. openRename()
// and openDelete() fill in the context; open() (Qt's Popup.open) reopens in the
// current mode, and onOpened restores the field from `tag`.
Popup {
  id: popup
  objectName: "tagManager"

  property string mode: "rename"
  property string tag: ""
  property int noteCount: 0
  // Flat [{tag, count}] list from `quill-store tags`, used only to warn about
  // a rename that lands on an existing tag.
  property var tags: []

  // A successful commit closes without emitting cancelled().
  property bool committed: false

  readonly property string bare: normalise(tagManagerField.text)
  readonly property bool spaced: hasWhitespace(bare)
  readonly property string mergeName: mergeTarget(bare)
  readonly property bool canRename: bare !== "" && !spaced && bare !== normalise(tag)

  signal commitRequested(string action, string tag, string next)
  signal cancelled()

  width: Style.space(380)
  padding: Style.space(12)
  modal: true
  dim: true
  focus: true
  popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

  function textOf(value) {
    return String(value === undefined || value === null ? "" : value)
  }

  function normalise(value) {
    var next = textOf(value).trim()
    while (next.charAt(0) === "#") next = next.slice(1).trim()
    return next
  }

  function hasWhitespace(value) {
    return /\s/.test(value)
  }

  function tagName(entry) {
    if (entry !== null && typeof entry === "object") return textOf(entry.tag)
    return textOf(entry)
  }

  // The existing tag a rename would merge into, or "". A case-only rename of
  // the tag itself is not a merge.
  function mergeTarget(value) {
    if (value === "") return ""
    var wanted = value.toLowerCase()
    var current = textOf(popup.tag).toLowerCase()
    var list = popup.tags && typeof popup.tags.length === "number" ? popup.tags : []
    for (var i = 0; i < list.length; i++) {
      var name = tagName(list[i])
      if (name === "") continue
      var lower = name.toLowerCase()
      if (lower !== wanted || lower === current) continue
      return name
    }
    return ""
  }

  function openRename(value, count) {
    popup.mode = "rename"
    popup.tag = textOf(value)
    popup.noteCount = Math.max(0, Math.floor(Number(count) || 0))
    popup.committed = false
    tagManagerField.text = popup.tag
    open()
  }

  function openDelete(value, count) {
    popup.mode = "delete"
    popup.tag = textOf(value)
    popup.noteCount = Math.max(0, Math.floor(Number(count) || 0))
    popup.committed = false
    tagManagerField.text = ""
    open()
  }

  function submit() {
    if (popup.mode === "delete") {
      finish("delete", "")
      return
    }
    if (!popup.canRename) return
    finish("rename", popup.bare)
  }

  function finish(action, next) {
    if (popup.committed) return
    popup.committed = true
    popup.commitRequested(action, popup.tag, next)
    popup.close()
  }

  onOpened: {
    if (popup.mode === "rename") {
      tagManagerField.text = popup.tag
      tagManagerField.forceActiveFocus()
      tagManagerField.selectAll()
    } else {
      tagManagerField.text = ""
    }
  }

  onClosed: {
    if (popup.committed) {
      popup.committed = false
      return
    }
    popup.cancelled()
  }

  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  contentItem: Column {
    width: popup.availableWidth
    spacing: Style.space(9)

    Text {
      width: parent.width
      text: popup.mode === "delete"
        ? "Delete #" + popup.tag : "Rename #" + popup.tag
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      width: parent.width
      visible: popup.mode === "rename"
      text: "Used by " + popup.noteCount
        + (popup.noteCount === 1 ? " note" : " notes")
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(Commons.Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: parent.width
      visible: popup.mode === "delete"
      text: "This removes #" + popup.tag + " from "
        + popup.noteCount + (popup.noteCount === 1 ? " note." : " notes.")
        + " Existing note versions are kept."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(Commons.Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    TextField {
      id: tagManagerField
      objectName: "tagManagerField"
      width: parent.width
      visible: popup.mode === "rename"
      placeholderText: "tag or nested/tag"
      font.pixelSize: Style.font.bodySmall
      onAccepted: popup.submit()
    }

    Text {
      width: parent.width
      visible: popup.mode === "rename"
      text: "Renaming onto an existing tag merges them"
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(Commons.Color.foreground, 0.45)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: popup.mode === "rename" && popup.mergeName !== ""
      text: "Will merge into #" + popup.mergeName
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: popup.mode === "rename" && popup.spaced
      text: "Tags cannot contain spaces"
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: Math.max(0, parent.width - tagManagerCancel.width
          - tagManagerCommit.width - parent.spacing * 2)
        height: 1
      }

      Button {
        id: tagManagerCancel
        objectName: "tagManagerCancel"
        text: "Cancel"
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(10)
        verticalPadding: Style.space(5)
        onClicked: popup.close()
      }

      Button {
        id: tagManagerCommit
        objectName: "tagManagerCommit"
        text: popup.mode === "delete" ? "Delete tag" : "Rename"
        active: popup.mode !== "delete"
        foreground: popup.mode === "delete"
          ? Commons.Color.urgent : Commons.Color.foreground
        enabled: popup.mode === "delete" || popup.canRename
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(10)
        verticalPadding: Style.space(5)
        onClicked: popup.submit()
      }
    }
  }
}
