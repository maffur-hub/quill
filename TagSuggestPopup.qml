import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TagSuggest.js" as TagSuggest

// Apply step for contextual tag suggestions. The extractor lives in
// TagSuggest.js and the caller owns the backend write: this popup only turns
// suggestions plus free text into one deduped list.
Popup {
  id: popup
  objectName: "tagSuggestPopup"

  property var suggestions: []
  property var existingTags: []
  property var selected: ({})
  property string errorText: ""
  property bool applying: false
  property bool didApply: false

  signal applied(var tags)
  signal cancelled()

  width: Style.space(380)
  padding: Style.space(12)
  modal: true
  dim: true
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  function resetFor(list, noteTags) {
    existingTags = Array.isArray(noteTags) ? noteTags : []
    var keys = existingKeys()
    var filtered = []
    var incoming = Array.isArray(list) ? list : []
    for (var i = 0; i < incoming.length; i++) {
      var tag = TagSuggest.normalizeTag(incoming[i])
      if (!tag || keys[tag]) continue
      keys[tag] = true
      filtered.push(tag)
    }
    suggestions = filtered
    selected = ({})
    errorText = ""
    applying = false
    didApply = false
    customField.text = ""
  }

  function openFor(list, noteTags) {
    resetFor(list, noteTags)
    open()
  }

  function isSelected(tag) {
    return selected[tag] === true
  }

  function toggle(tag) {
    var next = {}
    for (var key in selected) {
      if (selected[key] === true) next[key] = true
    }
    if (next[tag] === true) delete next[tag]
    else next[tag] = true
    selected = next
  }

  function existingKeys() {
    var keys = {}
    for (var i = 0; i < existingTags.length; i++) {
      var key = TagSuggest.normalizeTag(existingTags[i])
      if (key) keys[key] = true
    }
    return keys
  }

  function customList() {
    var parts = String(customField.text || "").split(/[\s,]+/)
    var output = []
    var seen = existingKeys()
    for (var i = 0; i < parts.length; i++) {
      var tag = TagSuggest.normalizeTag(parts[i])
      if (!tag || seen[tag]) continue
      seen[tag] = true
      output.push(tag)
    }
    return output
  }

  // Suggestions first (display order), then the free-text tags. The caller
  // applies this list in one `tag-add` call.
  function collectedTags() {
    var output = []
    var seen = existingKeys()
    for (var i = 0; i < suggestions.length; i++) {
      var tag = TagSuggest.normalizeTag(suggestions[i])
      if (!tag || seen[tag] || !isSelected(tag)) continue
      seen[tag] = true
      output.push(tag)
    }
    var custom = customList()
    for (var c = 0; c < custom.length; c++) {
      if (seen[custom[c]]) continue
      seen[custom[c]] = true
      output.push(custom[c])
    }
    return output
  }

  function applyNow() {
    if (applying || popup.didApply) return
    var tags = collectedTags()
    if (tags.length === 0) {
      errorText = "Select or type at least one tag"
      return
    }
    errorText = ""
    // Guard the signal: a rapid second Enter/Apply must not emit twice. The
    // caller's showError()/finishSuccess() resets `applying`.
    applying = true
    applied(tags)
  }

  function showError(message) {
    applying = false
    errorText = String(message || "Could not add tags")
  }

  function finishSuccess() {
    applying = false
    didApply = true
    close()
  }

  onOpened: {
    customField.forceActiveFocus()
  }
  onClosed: {
    if (!didApply) cancelled()
  }

  // Fallback for Enter while a suggestion chip (not the field) has focus.
  Shortcut {
    sequences: ["Return", "Enter"]
    enabled: popup.opened && !customField.activeFocus
    onActivated: popup.applyNow()
  }

  contentItem: Column {
    width: popup.availableWidth
    spacing: Style.space(9)

    Text {
      width: parent.width
      text: "Add tags"
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      width: parent.width
      visible: popup.suggestions.length === 0
      text: "No suggestions from this note — type a tag below."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(Commons.Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Flow {
      width: parent.width
      spacing: Style.space(5)
      visible: popup.suggestions.length > 0

      Repeater {
        model: popup.suggestions

        delegate: BorderSurface {
          id: suggestionChip
          objectName: "tagSuggestionChip"
          required property var modelData
          readonly property string tag: TagSuggest.normalizeTag(modelData)
          readonly property bool picked: popup.isSelected(tag)

          width: chipText.implicitWidth + Style.space(14)
          height: Style.space(20)
          color: picked
            ? Util.alpha(Commons.Color.accent, 0.22)
            : (chipMouse.containsMouse
              ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
              : Util.alpha(Commons.Color.foreground, 0.05))
          borderSpec: Border.flat(
            picked ? Util.alpha(Commons.Color.accent, 0.75)
                   : Util.alpha(Commons.Color.foreground, 0.16), 1)
          radius: Style.cornerRadius

          Text {
            id: chipText
            anchors.centerIn: parent
            text: "#" + suggestionChip.tag
            textFormat: Text.PlainText
            color: suggestionChip.picked
              ? Util.alpha(Commons.Color.accent, 1)
              : Util.alpha(Commons.Color.foreground, 0.78)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: suggestionChip.picked
          }

          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popup.toggle(suggestionChip.tag)
          }
        }
      }
    }

    TextField {
      id: customField
      objectName: "tagSuggestCustomField"
      width: parent.width
      placeholderText: "More tags, comma or space separated"
      font.pixelSize: Style.font.bodySmall
      onAccepted: popup.applyNow()
      onTextEdited: {
        if (popup.errorText !== "") popup.errorText = ""
      }
    }

    Text {
      width: parent.width
      visible: popup.errorText !== ""
      text: popup.errorText
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
        width: Math.max(0, parent.width - cancelButton.width - applyButton.width
          - parent.spacing * 2)
        height: 1
      }

      Button {
        id: cancelButton
        objectName: "tagSuggestCancelButton"
        text: "Cancel"
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(10)
        verticalPadding: Style.space(5)
        onClicked: popup.close()
      }

      Button {
        id: applyButton
        objectName: "tagSuggestApplyButton"
        text: popup.applying ? "Adding…" : "Apply"
        active: true
        enabled: !popup.applying && popup.collectedTags().length > 0
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(10)
        verticalPadding: Style.space(5)
        onClicked: popup.applyNow()
      }
    }
  }
}
