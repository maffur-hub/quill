import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Browse and edit the templates that seed new notes. The caller owns the
// popup's parent, centring, size and the `storePath` / `dataRoot` paths; this
// component only talks to `quill-store templates` and emits templatesChanged
// so the host can rebuild its create menu. The body is handed to the store
// through a throwaway markdown file, because command arguments are arrays and
// template bodies can be arbitrarily long.
Popup {
  id: root
  objectName: "templateManager"

  property string storePath: ""
  property string dataRoot: ""

  // Listing and editor state. The property is not called `templates` because
  // QML would generate a templatesChanged change signal, colliding with the
  // notification the host listens to below.
  property var templateEntries: []
  property int selectedIndex: -1
  // A new template keeps the slug editable until its first successful save.
  property bool isNew: true
  property bool loading: false
  property bool loadingTemplate: false
  property bool saving: false
  property bool deleting: false
  property bool deleteArmed: false
  property string errorText: ""
  property string statusText: ""

  // A refresh requested while a listing or a detail read is in flight runs
  // when that process exits. The selection is remembered across the rebuild so
  // the row the user just saved stays selected.
  property bool listReloadPending: false
  property string pendingSelectionId: ""
  property string pendingShowId: ""

  readonly property var selectedTemplate: (root.selectedIndex >= 0
    && root.selectedIndex < root.templateEntries.length)
    ? root.templateEntries[root.selectedIndex] : null
  readonly property string selectedId: root.selectedTemplate
    ? String(root.selectedTemplate.id || "") : ""

  signal templatesChanged()

  implicitWidth: Style.space(680)
  implicitHeight: Style.space(480)
  padding: Style.space(12)
  popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
  modal: true
  dim: true
  focus: true
  closePolicy: Popup.CloseOnEscape

  onOpened: {
    Qt.callLater(function() {
      if (root.templateEntries.length > 0) templateList.forceActiveFocus()
      else nameField.forceActiveFocus()
    })
  }
  onClosed: {
    root.deleteArmed = false
    deleteArmTimer.stop()
  }

  background: BorderSurface {
    color: Commons.Color.background
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
  }

  // `open` shadows Popup.open on purpose: the caller asks for a populated
  // manager, not just a visible popup. Setting visible (rather than calling
  // open again) avoids recursing into this function.
  function open() {
    root.visible = true
    root.templateEntries = []
    root.selectedIndex = -1
    root.isNew = true
    root.loading = false
    root.loadingTemplate = false
    root.deleteArmed = false
    root.errorText = ""
    root.statusText = ""
    root.listReloadPending = false
    root.pendingSelectionId = ""
    root.pendingShowId = ""
    deleteArmTimer.stop()
    root.resetEditor()
    root.loadList()
  }

  function close() {
    root.visible = false
  }

  function resetEditor() {
    nameField.text = ""
    descriptionField.text = ""
    iconField.text = ""
    idField.text = ""
    bodyArea.text = ""
  }

  function parseError(errorText, fallback) {
    var raw = String(errorText || "").trim()
    if (raw !== "") {
      try {
        var parsed = JSON.parse(raw)
        if (parsed && parsed.error) return String(parsed.error)
      } catch (error) {
        // Not JSON: use the raw message.
      }
      return raw
    }
    return fallback
  }

  function indexOfId(id) {
    var wanted = String(id || "")
    if (wanted === "") return -1
    for (var i = 0; i < root.templateEntries.length; i += 1) {
      if (String(root.templateEntries[i].id || "") === wanted) return i
    }
    return -1
  }

  // ---------------------------------------------------------------- listing

  function loadList() {
    if (root.storePath === "") {
      root.loading = false
      root.errorText = "Template store is not available"
      return
    }
    if (listProcess.running) {
      root.listReloadPending = true
      return
    }
    root.loading = true
    root.errorText = ""
    listProcess.outputText = ""
    listProcess.errorText = ""
    listProcess.command = [root.storePath, "templates", "list"]
    listProcess.running = true
  }

  function applyTemplates(exitCode, outputText, errorText) {
    root.loading = false
    // A listing requested while this one ran may predate the write that caused
    // it, so drop this result and ask again rather than selecting stale data.
    if (root.listReloadPending) {
      root.listReloadPending = false
      root.loadList()
      return
    }
    if (exitCode !== 0) {
      root.errorText = root.parseError(errorText, "Could not read templates")
      return
    }
    var result = {}
    try {
      result = JSON.parse(outputText || "{}")
    } catch (error) {
      root.errorText = "Could not read templates"
      return
    }
    var list = Array.isArray(result.templates) ? result.templates : []
    var previousId = root.selectedId
    root.templateEntries = list

    if (list.length === 0) {
      root.pendingSelectionId = ""
      root.startNew()
      return
    }

    var wanted = root.pendingSelectionId
    root.pendingSelectionId = ""
    var index = root.indexOfId(wanted)
    if (index < 0) index = root.indexOfId(previousId)
    if (index < 0) index = 0
    // A post-save or post-delete rebuild keeps its confirmation message; a
    // user-driven selection starts with a clean status line.
    root.selectTemplate(index, true)
  }

  function selectTemplate(index, keepStatus) {
    if (index < 0 || index >= root.templateEntries.length) return
    var entry = root.templateEntries[index]
    root.selectedIndex = index
    root.isNew = false
    root.deleteArmed = false
    deleteArmTimer.stop()
    root.errorText = ""
    if (!keepStatus) root.statusText = ""
    nameField.text = String(entry.name || "")
    descriptionField.text = String(entry.description || "")
    iconField.text = String(entry.icon || "")
    idField.text = String(entry.id || "")
    bodyArea.text = ""
    root.loadTemplate(String(entry.id || ""))
  }

  function stepSelection(delta) {
    if (root.templateEntries.length === 0) return
    var next = root.isNew ? 0 : root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > root.templateEntries.length - 1) next = root.templateEntries.length - 1
    root.selectTemplate(next)
  }

  function startNew() {
    root.selectedIndex = -1
    root.isNew = true
    root.deleteArmed = false
    root.loadingTemplate = false
    root.pendingShowId = ""
    root.errorText = ""
    root.statusText = ""
    deleteArmTimer.stop()
    root.resetEditor()
    if (root.visible) Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  // ------------------------------------------------------------- detail read

  function loadTemplate(id) {
    if (id === "" || root.storePath === "") return
    if (showProcess.running) {
      root.pendingShowId = id
      return
    }
    root.loadingTemplate = true
    showProcess.requestId = id
    showProcess.outputText = ""
    showProcess.errorText = ""
    showProcess.command = [root.storePath, "templates", "show", id]
    showProcess.running = true
  }

  function applyTemplate(exitCode, outputText, errorText) {
    root.loadingTemplate = false
    if (exitCode !== 0) {
      // Keep the summary fields the list already supplied; only the body is
      // missing. Surfacing the store message is more useful than blanking the
      // form.
      root.errorText = root.parseError(errorText, "Could not read this template")
    } else {
      var result = {}
      try {
        result = JSON.parse(outputText || "{}")
      } catch (error) {
        result = {}
      }
      // A selection change or a new form may have happened while the read was
      // in flight; only apply a result for the row that still owns the form.
      if (!root.isNew && String(result.id || "") === root.selectedId) {
        nameField.text = String(result.name || "")
        descriptionField.text = String(result.description || "")
        iconField.text = String(result.icon || "")
        idField.text = String(result.id || "")
        bodyArea.text = String(result.content || "")
      }
    }
    if (root.pendingShowId !== "") {
      var next = root.pendingShowId
      root.pendingShowId = ""
      root.loadTemplate(next)
    }
  }

  // ------------------------------------------------------------------- save

  function save() {
    if (root.saving || root.deleting) return
    if (root.loadingTemplate) {
      // Saving before the body has arrived would overwrite the template with
      // an empty body.
      root.errorText = "Still loading this template"
      return
    }
    if (root.storePath === "") {
      root.errorText = "Template store is not available"
      return
    }
    if (root.dataRoot === "") {
      root.errorText = "Template data directory is not configured"
      return
    }
    var id = root.isNew ? String(idField.text).trim() : root.selectedId
    // The list may still be rebuilding right after a save; the read-only id
    // field already holds the canonical slug in that gap.
    if (id === "") id = String(idField.text).trim()
    if (id === "") {
      root.errorText = root.isNew
        ? "Enter a slug for the new template" : "Select a template to save"
      if (root.isNew) idField.forceActiveFocus()
      return
    }

    root.saving = true
    root.deleteArmed = false
    deleteArmTimer.stop()
    root.errorText = ""
    root.statusText = "Saving…"

    var temp = root.dataRoot + "/.template-" + Date.now() + ".md"
    // Snapshot the form at creation time, so edits made while the temp file is
    // written cannot desynchronise the flags from the body being saved.
    var view = templateFileComponent.createObject(root, {
      path: temp,
      targetId: id,
      targetName: String(nameField.text).trim(),
      targetDescription: String(descriptionField.text).trim(),
      targetIcon: String(iconField.text).trim()
    })
    if (!view) {
      root.saving = false
      root.statusText = ""
      root.errorText = "Could not prepare the template body"
      return
    }
    view.setText(String(bodyArea.text))
  }

  function tempFileSaved(view) {
    var temp = String(view.path || "")
    var id = String(view.targetId || "")
    var name = String(view.targetName || "")
    var description = String(view.targetDescription || "")
    var icon = String(view.targetIcon || "")
    view.destroy()
    if (temp === "") {
      root.saving = false
      root.statusText = ""
      root.errorText = "Could not prepare the template body"
      return
    }

    var args = [root.storePath, "templates", "save", id]
    if (name !== "") args.push("--name", name)
    if (description !== "") args.push("--description", description)
    if (icon !== "") args.push("--icon", icon)
    args.push("--content-file", temp)

    saveProcess.pendingTemp = temp
    saveProcess.pendingId = id
    saveProcess.outputText = ""
    saveProcess.errorText = ""
    saveProcess.command = args
    saveProcess.running = true
  }

  function tempFileFailed(view, error) {
    var temp = String(view.path || "")
    view.destroy()
    root.saving = false
    root.statusText = ""
    var detail = String(error === undefined ? "" : error).trim()
    root.errorText = detail === ""
      ? "Could not write the template body"
      : "Could not write the template body: " + detail
    if (temp !== "") root.removeTemp(temp)
  }

  function finishSave(exitCode, outputText, errorText) {
    var temp = String(saveProcess.pendingTemp || "")
    var requestedId = String(saveProcess.pendingId || "")
    saveProcess.pendingTemp = ""
    saveProcess.pendingId = ""
    root.saving = false
    // The store has already read the body, so the temp file can go whether the
    // command succeeded or not.
    if (temp !== "") root.removeTemp(temp)

    if (exitCode !== 0) {
      root.statusText = ""
      root.errorText = root.parseError(errorText, "Could not save the template")
      return
    }

    var result = {}
    try {
      result = JSON.parse(outputText || "{}")
    } catch (error) {
      result = {}
    }
    var savedId = String(result.id || requestedId)
    if (savedId === "") savedId = requestedId

    // The store returns the canonical slug and the merged fields. Apply them
    // before the reload so the form never flashes back to the pre-save id.
    root.isNew = false
    root.deleteArmed = false
    idField.text = savedId
    if (result.name !== undefined) nameField.text = String(result.name || "")
    if (result.description !== undefined) descriptionField.text = String(result.description || "")
    if (result.icon !== undefined) iconField.text = String(result.icon || "")
    if (result.content !== undefined) bodyArea.text = String(result.content || "")
    root.errorText = ""
    root.statusText = "Saved"
    root.pendingSelectionId = savedId
    root.templatesChanged()
    root.loadList()
  }

  function removeTemp(path) {
    Quickshell.execDetached(["rm", "-f", "--", String(path)])
  }

  // ----------------------------------------------------------------- delete

  function requestDelete() {
    if (root.isNew || root.selectedIndex < 0) return
    if (root.saving || root.deleting) return
    if (!root.deleteArmed) {
      root.deleteArmed = true
      root.errorText = ""
      root.statusText = "Click Delete again to confirm"
      deleteArmTimer.restart()
      return
    }

    root.deleteArmed = false
    deleteArmTimer.stop()
    var id = root.selectedId
    if (id === "") return
    root.deleting = true
    root.errorText = ""
    root.statusText = "Deleting…"
    deleteProcess.targetId = id
    deleteProcess.outputText = ""
    deleteProcess.errorText = ""
    deleteProcess.command = [root.storePath, "templates", "delete", id]
    deleteProcess.running = true
  }

  function finishDelete(exitCode, outputText, errorText) {
    root.deleting = false
    if (exitCode !== 0) {
      root.statusText = ""
      root.errorText = root.parseError(errorText, "Could not delete this template")
      return
    }
    root.errorText = ""
    root.statusText = "Template deleted"
    root.pendingSelectionId = ""
    root.templatesChanged()
    root.loadList()
  }

  // ------------------------------------------------------------------- view

  contentItem: Item {
    width: root.availableWidth
    height: root.availableHeight

    Column {
      id: layout
      anchors.fill: parent
      spacing: Style.space(10)

      Column {
        id: headerBlock
        width: parent.width
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: "Templates"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: "Reuse a starting point when creating a note."
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: bodyRow
        width: parent.width
        height: Math.max(0, parent.height - headerBlock.height - footerBlock.height
          - layout.spacing * 2)
        spacing: Style.space(10)

        // ------------------------------------------------------- left column
        BorderSurface {
          id: listPane
          width: Math.max(Style.space(180),
            Math.min(Style.space(250), Math.floor((bodyRow.width - bodyRow.spacing) * 0.34)))
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.022)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(4)
            spacing: Style.space(4)

            Button {
              id: newTemplateButton
              objectName: "templateNew"
              width: parent.width
              text: "New template"
              leftAlign: true
              active: root.isNew
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              onClicked: root.startNew()
            }

            ListView {
              id: templateList
              objectName: "templateList"
              width: parent.width
              height: Math.max(0, parent.height - newTemplateButton.height - parent.spacing)
              clip: true
              spacing: Style.space(2)
              model: root.templateEntries
              boundsBehavior: Flickable.StopAtBounds

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Up) {
                  root.stepSelection(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.stepSelection(1)
                  event.accepted = true
                }
              }

              delegate: BorderSurface {
                id: templateRow
                required property var modelData
                required property int index

                readonly property bool rowSelected: !root.isNew && root.selectedIndex === index
                readonly property string rowIcon: String(modelData.icon || "")

                objectName: "templateRow-" + String(modelData.id || index)
                width: templateList.width
                height: Style.space(48)
                color: templateRow.rowSelected
                  ? Style.selectedAccentFill
                  : rowMouse.containsMouse
                    ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                    : "transparent"
                borderSpec: templateRow.rowSelected
                  ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent)
                  : Border.none()
                radius: Style.cornerRadius

                Rectangle {
                  visible: templateRow.rowSelected
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Style.space(3)
                  color: Commons.Color.accent
                }

                Text {
                  id: rowIconText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(9)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  text: templateRow.rowIcon !== "" ? templateRow.rowIcon : "·"
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  color: templateRow.rowIcon !== ""
                    ? Commons.Color.foreground
                    : Util.alpha(Commons.Color.foreground, 0.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Column {
                  anchors.left: rowIconText.right
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(7)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    width: parent.width
                    text: String(templateRow.modelData.name || templateRow.modelData.id || "")
                    textFormat: Text.PlainText
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: String(templateRow.modelData.description || "")
                    textFormat: Text.PlainText
                    color: Util.alpha(Commons.Color.foreground, 0.42)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.selectTemplate(templateRow.index)
                }
              }
            }
          }

          Text {
            objectName: "templateListEmpty"
            anchors.centerIn: parent
            anchors.verticalCenterOffset: Style.space(18)
            width: parent.width - Style.space(20)
            visible: !root.loading && root.templateEntries.length === 0
            text: "No templates yet. Create one on the right."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: Style.space(18)
            width: parent.width - Style.space(20)
            visible: root.loading && root.templateEntries.length === 0
            text: "Loading templates…"
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            color: Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------ right column
        BorderSurface {
          id: editorPane
          width: parent.width - listPane.width - parent.spacing
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.022)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          Item {
            anchors.fill: parent
            anchors.margins: Style.space(8)

            Text {
              id: editorTitle
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              text: root.isNew ? "New template" : "Edit template"
              textFormat: Text.PlainText
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Column {
              id: metaFields
              anchors.top: editorTitle.bottom
              anchors.topMargin: Style.space(6)
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(5)

              Column {
                width: parent.width
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Name"
                  textFormat: Text.PlainText
                  color: Util.alpha(Commons.Color.foreground, 0.48)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: nameField
                  objectName: "templateName"
                  width: parent.width
                  placeholderText: "Template name"
                  font.pixelSize: Style.font.bodySmall
                  onTextEdited: if (root.errorText !== "") root.errorText = ""
                  onAccepted: root.save()
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Description"
                  textFormat: Text.PlainText
                  color: Util.alpha(Commons.Color.foreground, 0.48)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: descriptionField
                  objectName: "templateDescription"
                  width: parent.width
                  placeholderText: "One line shown in the list"
                  font.pixelSize: Style.font.bodySmall
                  onTextEdited: if (root.errorText !== "") root.errorText = ""
                  onAccepted: root.save()
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: Style.space(64)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: "Icon"
                    textFormat: Text.PlainText
                    color: Util.alpha(Commons.Color.foreground, 0.48)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  TextField {
                    id: iconField
                    objectName: "templateIcon"
                    width: parent.width
                    placeholderText: "✦"
                    horizontalAlignment: Qt.AlignHCenter
                    font.pixelSize: Style.font.bodySmall
                    onTextEdited: if (root.errorText !== "") root.errorText = ""
                    onAccepted: root.save()
                  }
                }

                Column {
                  width: parent.width - Style.space(64) - parent.spacing
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: root.isNew ? "Slug" : "Slug (fixed)"
                    textFormat: Text.PlainText
                    color: Util.alpha(Commons.Color.foreground, root.isNew ? 0.48 : 0.36)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  TextField {
                    id: idField
                    objectName: "templateId"
                    width: parent.width
                    readOnly: !root.isNew
                    maximumLength: 64
                    placeholderText: root.isNew ? "e.g. weekly-review" : ""
                    foreground: root.isNew
                      ? Commons.Color.foreground
                      : Util.alpha(Commons.Color.foreground, 0.6)
                    font.pixelSize: Style.font.bodySmall
                    onTextEdited: if (root.errorText !== "") root.errorText = ""
                    onAccepted: root.save()
                  }
                }
              }
            }

            Text {
              id: bodyLabel
              anchors.top: metaFields.bottom
              anchors.topMargin: Style.space(6)
              anchors.left: parent.left
              anchors.right: parent.right
              text: "Body"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.48)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            ScrollView {
              id: bodyScroll
              anchors.top: bodyLabel.bottom
              anchors.topMargin: Style.space(2)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true
              background: null

              TextArea {
                id: bodyArea
                objectName: "templateBody"
                width: bodyScroll.availableWidth
                textFormat: TextEdit.PlainText
                wrapMode: TextArea.Wrap
                selectByMouse: true
                color: Commons.Color.foreground
                selectionColor: Style.selectionFillFor(Commons.Color.foreground, Commons.Color.accent)
                selectedTextColor: Commons.Color.foreground
                placeholderText: "Write the template body…"
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
                padding: Style.space(8)
                background: null
              }
            }

            Text {
              anchors.centerIn: bodyScroll
              visible: root.loadingTemplate
              text: "Loading…"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.42)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ---------------------------------------------------------------- footer
      Column {
        id: footerBlock
        width: parent.width
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: "{{date}}, {{time}} and {{datetime}} are replaced on create"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.42)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: Math.max(0, parent.width - closeButton.width - deleteButton.width
              - saveButton.width - parent.spacing * 3)
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorText !== "" ? root.errorText : root.statusText
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.errorText !== ""
              ? Commons.Color.urgent
              : Util.alpha(Commons.Color.foreground, 0.48)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            id: closeButton
            objectName: "templateClose"
            anchors.verticalCenter: parent.verticalCenter
            text: "Close"
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(5)
            onClicked: root.close()
          }

          Button {
            id: deleteButton
            objectName: "templateDelete"
            anchors.verticalCenter: parent.verticalCenter
            text: root.deleting
              ? "Deleting…"
              : root.deleteArmed ? "Confirm delete" : "Delete…"
            active: root.deleteArmed
            foreground: root.deleteArmed ? Commons.Color.urgent : Commons.Color.foreground
            enabled: !root.isNew && root.selectedIndex >= 0
              && !root.saving && !root.deleting
            opacity: enabled ? 1 : 0.4
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(5)
            onClicked: root.requestDelete()
          }

          Button {
            id: saveButton
            objectName: "templateSave"
            anchors.verticalCenter: parent.verticalCenter
            text: root.saving ? "Saving…" : "Save"
            active: true
            enabled: !root.saving && !root.deleting && !root.loadingTemplate
              && root.storePath !== ""
            opacity: enabled ? 1 : 0.4
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(5)
            onClicked: root.save()
          }
        }
      }
    }
  }

  Timer {
    id: deleteArmTimer
    interval: 4000
    onTriggered: {
      if (!root.deleteArmed) return
      root.deleteArmed = false
      if (root.statusText === "Click Delete again to confirm") root.statusText = ""
    }
  }

  // One-shot writer for the template body. atomicWrites keeps the store from
  // reading a half-written file; blockAllReads stops FileView trying to load
  // the non-existent path when the object is created.
  Component {
    id: templateFileComponent

    FileView {
      id: templateFileView
      property string targetId: ""
      property string targetName: ""
      property string targetDescription: ""
      property string targetIcon: ""
      atomicWrites: true
      blockAllReads: true
      printErrors: false
      onSaved: root.tempFileSaved(templateFileView)
      onSaveFailed: function(error) { root.tempFileFailed(templateFileView, error) }
    }
  }

  Process {
    id: listProcess
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: listProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: listProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      root.applyTemplates(exitCode, listProcess.outputText, listProcess.errorText)
    }
  }

  Process {
    id: showProcess
    property string requestId: ""
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: showProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: showProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      root.applyTemplate(exitCode, showProcess.outputText, showProcess.errorText)
    }
  }

  Process {
    id: saveProcess
    property string pendingTemp: ""
    property string pendingId: ""
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: saveProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: saveProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      root.finishSave(exitCode, saveProcess.outputText, saveProcess.errorText)
    }
  }

  Process {
    id: deleteProcess
    property string targetId: ""
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: deleteProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: deleteProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) {
      root.finishDelete(exitCode, deleteProcess.outputText, deleteProcess.errorText)
    }
  }
}
