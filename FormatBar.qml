import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MarkdownFormat.js" as MarkdownFormat
import "EmojiData.js" as EmojiData

// Formatting toolbar for the library editor.
//
// Buttons never take focus. The bar itself is a horizontal Flickable so it
// stays usable when the editor is only a few dozen pixels wide; popovers are
// themed overlays rather than native menus.
Item {
  id: root
  objectName: "quillFormatBar"

  property bool available: true
  property bool canUndo: false
  property bool canRedo: false
  property string linkValue: ""
  // Populated by Library from the notes index. Titles are already deduped and
  // sorted; the popup only filters them.
  property var noteTitles: []
  property string noteLinkQuery: ""
  readonly property var noteLinkMatches: filterNoteTitles(noteLinkQuery)
  property string emojiQuery: ""
  readonly property var emojiMatches: EmojiData.filter(root.emojiQuery)

  signal action(string name, var value)

  property string lastColor: "#e03e2d"
  property int tableHoverRow: -1
  property int tableHoverCol: -1
  // Custom picker state: hue in degrees, saturation/value 0..1.
  property real pickerHue: 0
  property real pickerSat: 1
  property real pickerVal: 1
  readonly property var pickerRgb: hsvToRgb(pickerHue, pickerSat, pickerVal)
  readonly property int pickerRed: pickerRgb[0]
  readonly property int pickerGreen: pickerRgb[1]
  readonly property int pickerBlue: pickerRgb[2]
  readonly property string pickerHex: "#" + hexChannel(pickerRed) + hexChannel(pickerGreen)
    + hexChannel(pickerBlue)
  readonly property color pickerColour: Qt.rgba(pickerRed / 255, pickerGreen / 255,
    pickerBlue / 255, 1)

  readonly property real contentWidth: barScroll.contentWidth
  readonly property real viewportWidth: barScroll.width
  // Exposed for the e2e harness and keyboard tests without reaching into the
  // popup scene. Colours are applied from the custom picker's hex field/Save.
  readonly property Item colorInput: colorPickerHexField
  readonly property Item colorApplyButton: colorPickerSave
  readonly property Item linkInput: linkField
  readonly property Item linkApplyButton: linkApply
  readonly property Item noteLinkInput: noteLinkField
  readonly property var colorPalettePopup: colorPopup
  readonly property var colorPickerPopup: colorPicker
  readonly property var noteLinkPopupRef: noteLinkPopup
  readonly property var insertPopupRef: insertPopup
  readonly property Item emojiInput: emojiSearch
  readonly property var emojiPopupRef: emojiPopup
  readonly property Item emojiInsertItem: insertEmojiItem

  onVisibleChanged: if (!visible) closePopovers()
  onAvailableChanged: if (!available) closePopovers()
  onPickerHueChanged: if (svCanvas) svCanvas.requestPaint()

  // TinyMCE 6's default text-colour palette, as used by Joplin.
  readonly property var paletteSwatches: [
    "#BFEDD2", "#FBEEB8", "#F8CAC6", "#ECCAFA", "#C2E0F4",
    "#2DC26B", "#F1C40F", "#E03E2D", "#B96AD9", "#3598DB",
    "#169179", "#E67E23", "#BA372A", "#843FA1", "#236FA1",
    "#ECF0F1", "#CED4D9", "#95A5A6", "#7E8C8D", "#34495E"
  ]
  readonly property var paletteBase: ["#000000", "#FFFFFF"]

  function clampUnit(value) {
    return Math.max(0, Math.min(1, value))
  }

  function hexChannel(value) {
    var text = Math.max(0, Math.min(255, Math.round(value))).toString(16)
    return text.length < 2 ? "0" + text : text
  }

  function hueHex(hue) {
    var rgb = hsvToRgb(hue, 1, 1)
    return "#" + hexChannel(rgb[0]) + hexChannel(rgb[1]) + hexChannel(rgb[2])
  }

  function hsvToRgb(hue, saturation, value) {
    var h = ((hue % 360) + 360) % 360
    var c = value * saturation
    var x = c * (1 - Math.abs((h / 60) % 2 - 1))
    var m = value - c
    var r = 0
    var g = 0
    var b = 0
    if (h < 60) { r = c; g = x }
    else if (h < 120) { r = x; g = c }
    else if (h < 180) { g = c; b = x }
    else if (h < 240) { g = x; b = c }
    else if (h < 300) { r = x; b = c }
    else { r = c; b = x }
    return [Math.round((r + m) * 255), Math.round((g + m) * 255),
      Math.round((b + m) * 255)]
  }

  function rgbToHsv(red, green, blue) {
    var r = red / 255
    var g = green / 255
    var b = blue / 255
    var max = Math.max(r, g, b)
    var min = Math.min(r, g, b)
    var delta = max - min
    var hue = 0
    if (delta !== 0) {
      if (max === r) hue = ((g - b) / delta) % 6
      else if (max === g) hue = (b - r) / delta + 2
      else hue = (r - g) / delta + 4
      hue *= 60
      if (hue < 0) hue += 360
    }
    return { h: hue, s: max === 0 ? 0 : delta / max, v: max }
  }

  function setPickerRgb(red, green, blue) {
    var hsv = rgbToHsv(red, green, blue)
    root.pickerHue = hsv.h
    root.pickerSat = hsv.s
    root.pickerVal = hsv.v
    root.syncPickerFields()
  }

  function setPickerHex(value) {
    var hex = MarkdownFormat.colourToHex(value)
    if (hex === null) return false
    root.setPickerRgb(parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16),
      parseInt(hex.slice(5, 7), 16))
    return true
  }

  function syncPickerFields() {
    if (!colorPickerRed.activeFocus) colorPickerRed.text = String(root.pickerRed)
    if (!colorPickerGreen.activeFocus) colorPickerGreen.text = String(root.pickerGreen)
    if (!colorPickerBlue.activeFocus) colorPickerBlue.text = String(root.pickerBlue)
    if (!colorPickerHexField.activeFocus) colorPickerHexField.text = root.pickerHex
  }

  function commitPickerHex() {
    var hex = MarkdownFormat.colourToHex(colorPickerHexField.text)
    if (hex === null) return false
    root.setPickerHex(hex)
    return true
  }

  function commitPickerRgb() {
    var fields = [colorPickerRed, colorPickerGreen, colorPickerBlue]
    var channels = []
    for (var i = 0; i < fields.length; i++) {
      var raw = fields[i].text.trim()
      if (!/^[0-9]{1,3}$/.test(raw)) return false
      var value = Number(raw)
      if (value < 0 || value > 255) return false
      channels.push(value)
    }
    root.setPickerRgb(channels[0], channels[1], channels[2])
    return true
  }

  function commitPickerFields() {
    // Prefer the RGB fields only while one of them is being edited; otherwise
    // the hex field is the canonical source (Save must use typed hex even when
    // the field did not receive focus, e.g. from the e2e harness).
    if (colorPickerRed.activeFocus || colorPickerGreen.activeFocus
      || colorPickerBlue.activeFocus) {
      return root.commitPickerRgb()
    }
    return root.commitPickerHex()
  }

  function openColourPicker() {
    if (!available) return
    closePopovers()
    root.setPickerHex(MarkdownFormat.colourToHex(root.lastColor) || "#e03e2d")
    colorPicker.open()
  }

  function savePickerColour() {
    // Refuse to save when the field the user is editing is not a valid colour;
    // silently applying the previous colour would look like a hex typo worked.
    if (!root.commitPickerFields()) return false
    var colour = MarkdownFormat.normaliseColour(root.pickerHex)
    if (colour === null) return false
    root.lastColor = root.pickerHex
    root.invoke("color", colour)
    colorPicker.close()
    colorPopup.close()
    return true
  }

  function applySwatch(hex) {
    var normalised = MarkdownFormat.normaliseHex(hex)
    if (normalised === null) return false
    root.lastColor = normalised
    root.invoke("color", MarkdownFormat.normaliseColour(normalised))
    colorPopup.close()
    return true
  }

  function noColour() {
    root.invoke("noColour", "")
    colorPopup.close()
  }

  function isLastColour(hex) {
    var a = MarkdownFormat.normaliseHex(hex)
    var b = MarkdownFormat.normaliseHex(root.lastColor)
    return a !== null && b !== null && a === b
  }

  function contrastColour(hex) {
    var value = MarkdownFormat.colourToHex(hex)
    if (value === null) return Commons.Color.foreground
    var red = parseInt(value.slice(1, 3), 16)
    var green = parseInt(value.slice(3, 5), 16)
    var blue = parseInt(value.slice(5, 7), 16)
    return (0.299 * red + 0.587 * green + 0.114 * blue) > 150 ? "#101315" : "#ffffff"
  }

  function invoke(name, value) {
    if (!available) return
    root.action(name, value)
  }

  // ------------------------------------------------------------ insert helpers
  // Date/time are computed here at click time so the engine stays pure. The
  // combined "Date and time" item is deliberately absent: date/time actions
  // validate their whole value, so two inserts cannot be combined.
  function pad2(value) {
    return (value < 10 ? "0" : "") + value
  }

  function isoDate(date) {
    return date.getFullYear() + "-" + root.pad2(date.getMonth() + 1) + "-"
      + root.pad2(date.getDate())
  }

  function isoTime(date) {
    return root.pad2(date.getHours()) + ":" + root.pad2(date.getMinutes())
  }

  function insertDate() {
    insertPopup.close()
    root.invoke("date", root.isoDate(new Date()))
  }

  function insertTime() {
    insertPopup.close()
    root.invoke("time", root.isoTime(new Date()))
  }

  function filterNoteTitles(query) {
    var wanted = String(query || "").trim().toLowerCase()
    var source = root.noteTitles || []
    var output = []
    for (var i = 0; i < source.length; i++) {
      var title = String(source[i] === undefined || source[i] === null ? "" : source[i])
      if (title === "") continue
      if (wanted !== "" && title.toLowerCase().indexOf(wanted) < 0) continue
      output.push(title)
    }
    return output
  }

  function insertNoteLink(title) {
    var value = String(title || "").trim()
    if (value === "") return false
    root.invoke("noteLink", value)
    noteLinkPopup.close()
    return true
  }

  function insertEmoji(glyph) {
    var value = String(glyph || "")
    if (value === "") return false
    root.invoke("emoji", value)
    emojiPopup.close()
    return true
  }

  function insertFirstEmoji() {
    if (root.emojiMatches.length === 0) return false
    return root.insertEmoji(root.emojiMatches[0].glyph)
  }

  function placePopup(popup, anchorItem) {
    var point = anchorItem.mapToItem(root, 0, 0)
    popup.x = Math.max(Style.space(4), Math.min(root.width - popup.width - Style.space(4),
      point.x))
    popup.y = point.y + anchorItem.height + Style.space(4)
  }

  function closePopovers() {
    colorPopup.close()
    colorPicker.close()
    sizePopup.close()
    linkPopup.close()
    tablePopup.close()
    headingPopup.close()
    insertPopup.close()
    noteLinkPopup.close()
    emojiPopup.close()
  }

  function openColorPopover() {
    if (!available) return
    closePopovers()
    placePopup(colorPopup, colorButton)
    colorPopup.open()
  }

  function openSizePopover() {
    if (!available) return
    closePopovers()
    placePopup(sizePopup, sizeButton)
    sizePopup.open()
  }

  function openLinkPopover() {
    if (!available) return
    closePopovers()
    placePopup(linkPopup, linkButton)
    linkField.text = root.linkValue
    linkPopup.open()
    linkField.forceActiveFocus()
    linkField.selectAll()
  }

  function openTablePopover() {
    if (!available) return
    closePopovers()
    placePopup(tablePopup, tableButton)
    root.tableHoverRow = -1
    root.tableHoverCol = -1
    tablePopup.open()
  }

  function openHeadingPopover() {
    if (!available) return
    closePopovers()
    placePopup(headingPopup, headingButton)
    headingPopup.open()
  }

  function openInsertPopover() {
    if (!available) return
    closePopovers()
    placePopup(insertPopup, insertButton)
    insertPopup.open()
  }

  function openNoteLink() {
    if (!available) return
    closePopovers()
    // placePopup maps the button out of the scrolling row, so the popup stays
    // inside the bar even when the row is scrolled sideways.
    placePopup(noteLinkPopup, insertButton)
    root.noteLinkQuery = ""
    noteLinkField.text = ""
    noteLinkPopup.open()
    noteLinkField.forceActiveFocus()
  }

  function openEmojiPopover() {
    if (!available) return
    closePopovers()
    placePopup(emojiPopup, insertButton)
    root.emojiQuery = ""
    emojiSearch.text = ""
    emojiPopup.open()
    emojiSearch.forceActiveFocus()
  }

  height: Style.space(28)

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Commons.Color.foreground, 0.016)
    radius: Style.cornerRadius
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 1
    color: Util.alpha(Commons.Color.foreground, 0.08)
  }

  Flickable {
    id: barScroll
    anchors.fill: parent
    anchors.leftMargin: Style.space(2)
    anchors.rightMargin: Style.space(2)
    clip: true
    contentWidth: barRow.width
    contentHeight: height
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentWidth > width

    WheelHandler {
      onWheel: function(event) {
        if (barScroll.contentWidth <= barScroll.width) return
        var step = event.angleDelta.y !== 0 ? -event.angleDelta.y : event.angleDelta.x
        barScroll.contentX = Math.max(0, Math.min(barScroll.contentWidth - barScroll.width,
          barScroll.contentX + step))
        event.accepted = true
      }
    }

    Row {
      id: barRow
      objectName: "formatBarRow"
      height: Style.space(23)
      y: Math.floor((barScroll.height - height) / 2)
      spacing: Style.space(1)

      FmtButton {
        glyph: "↶"
        tip: "Undo (Ctrl+Z)"
        enabled: root.available && root.canUndo
        onActivated: root.invoke("undo")
      }
      FmtButton {
        glyph: "↷"
        tip: "Redo (Ctrl+Shift+Z)"
        enabled: root.available && root.canRedo
        onActivated: root.invoke("redo")
      }

      Divider {}

      FmtButton { glyph: "B"; tip: "Bold (Ctrl+B)"; onActivated: root.invoke("bold") }
      FmtButton { glyph: "I"; tip: "Italic (Ctrl+I)"; onActivated: root.invoke("italic") }
      FmtButton { glyph: "U"; tip: "Underline (Ctrl+U)"; onActivated: root.invoke("underline") }
      FmtButton { glyph: "S"; tip: "Strikethrough (Ctrl+Shift+X)"; onActivated: root.invoke("strike") }

      Divider {}

      FmtButton {
        objectName: "formatHighlightButton"
        glyph: "▨"
        tip: "Highlight (Ctrl+Shift+H)"
        onActivated: root.invoke("highlight")
      }
      // Joplin-style colour control: an "A", a last-used underline and a
      // chevron. The wrapper keeps the button 30 px wide (within the 23–30 px
      // toolbar rhythm) while the glyph itself stays a normal FmtButton.
      Item {
        width: Style.space(30)
        height: Style.space(23)

        FmtButton {
          id: colorButton
          width: parent.width
          height: parent.height
          glyph: ""
          tip: "Colour"
          onActivated: root.openColorPopover()
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: Style.space(-2)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -1
          text: "A"
          textFormat: Text.PlainText
          color: root.available ? Commons.Color.foreground
            : Util.alpha(Commons.Color.foreground, 0.38)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: Style.space(-2)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          width: Style.space(9)
          height: 2
          color: root.available ? root.lastColor
            : Util.alpha(Commons.Color.foreground, 0.25)
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          text: "▾"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.72)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
      FmtButton {
        id: sizeButton
        glyph: "A"
        tip: "Text size"
        onActivated: root.openSizePopover()
      }
      FmtButton {
        objectName: "formatSuperscriptButton"
        glyph: "x²"
        tip: "Superscript"
        onActivated: root.invoke("superscript")
      }
      FmtButton {
        objectName: "formatSubscriptButton"
        glyph: "x₂"
        tip: "Subscript"
        onActivated: root.invoke("subscript")
      }

      Divider {}

      Item {
        width: Style.space(30)
        height: Style.space(23)

        FmtButton {
          id: headingButton
          objectName: "formatHeadingButton"
          width: parent.width
          height: parent.height
          glyph: ""
          tip: "Heading"
          onActivated: root.openHeadingPopover()
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: Style.space(-2)
          anchors.verticalCenter: parent.verticalCenter
          text: "H"
          textFormat: Text.PlainText
          color: root.available ? Commons.Color.foreground
            : Util.alpha(Commons.Color.foreground, 0.38)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          text: "▾"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.72)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Divider {}

      FmtButton { glyph: "•"; tip: "Bullet list"; onActivated: root.invoke("bullet") }
      FmtButton { glyph: "1."; tip: "Numbered list"; onActivated: root.invoke("number") }
      FmtButton { glyph: "☐"; tip: "Task list"; onActivated: root.invoke("task") }
      FmtButton { glyph: "❝"; tip: "Blockquote"; onActivated: root.invoke("quote") }

      Divider {}

      FmtButton {
        id: linkButton
        glyph: "↗"
        tip: "Link (Ctrl+K)"
        onActivated: root.openLinkPopover()
      }
      FmtButton {
        objectName: "formatInlineCodeButton"
        glyph: "`"
        tip: "Inline code"
        onActivated: root.invoke("code")
      }
      FmtButton { glyph: "{}"; tip: "Code block"; onActivated: root.invoke("codeblock") }

      Divider {}

      FmtButton { glyph: "—"; tip: "Horizontal rule"; onActivated: root.invoke("hr") }
      FmtButton {
        id: tableButton
        glyph: "▦"
        tip: "Insert table"
        onActivated: root.openTablePopover()
      }

      Divider {}

      FmtButton {
        id: insertButton
        objectName: "formatInsertButton"
        glyph: "⊕"
        tip: "Insert"
        onActivated: root.openInsertPopover()
      }

      Divider {}

      FmtButton { glyph: "Tx"; tip: "Clear formatting"; onActivated: root.invoke("clear") }

      Item { width: Style.space(2); height: 1 }
    }
  }

  // ------------------------------------------------------------------ popups

  // Swatch palette. Clicking a cell applies the colour immediately, exactly
  // like Joplin/TinyMCE; there is deliberately no Apply button here.
  Popup {
    id: colorPopup
    width: Style.space(152)
    padding: Style.space(8)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Text {
        text: "Text colour"
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Grid {
        columns: 5
        spacing: Style.space(2)
        Repeater {
          model: root.paletteSwatches
          SwatchCell {
            required property var modelData
            swatch: String(modelData)
            active: root.isLastColour(String(modelData))
            onPicked: root.applySwatch(String(modelData))
          }
        }
      }

      Row {
        spacing: Style.space(2)

        Repeater {
          model: root.paletteBase
          SwatchCell {
            required property var modelData
            swatch: String(modelData)
            active: root.isLastColour(String(modelData))
            onPicked: root.applySwatch(String(modelData))
          }
        }

        // "No colour": transparent cell with a diagonal slash.
        Rectangle {
          width: Style.space(24)
          height: Style.space(22)
          radius: Style.space(3)
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(Commons.Color.foreground, 0.22)

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(17)
            height: 1
            rotation: -45
            color: Util.alpha(Commons.Color.foreground, 0.72)
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.noColour()
          }
        }

        // Palette icon: opens the custom picker.
        Rectangle {
          width: Style.space(24)
          height: Style.space(22)
          radius: Style.space(3)
          color: Util.alpha(Commons.Color.foreground, 0.06)
          border.width: 1
          border.color: Util.alpha(Commons.Color.foreground, 0.22)

          Canvas {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            onPaint: {
              var ctx = getContext("2d")
              var w = width
              var h = height
              ctx.clearRect(0, 0, w, h)
              ctx.strokeStyle = String(Util.alpha(Commons.Color.foreground, 0.66))
              ctx.lineWidth = 1.2
              ctx.beginPath()
              ctx.arc(w / 2, h / 2, Math.min(w, h) / 2 - 1, 0, Math.PI * 2)
              ctx.stroke()
              var dots = ["#E03E2D", "#F1C40F", "#2DC26B", "#3598DB"]
              for (var i = 0; i < dots.length; i++) {
                var angle = -Math.PI / 2 + i * Math.PI / 2
                ctx.beginPath()
                ctx.arc(w / 2 + Math.cos(angle) * w * 0.18,
                  h / 2 + Math.sin(angle) * h * 0.18, 1.5, 0, Math.PI * 2)
                ctx.fillStyle = dots[i]
                ctx.fill()
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openColourPicker()
          }
        }
      }
    }
  }

  // Joplin-style modal picker: SV square, hue strip, RGB/hex fields, preview.
  // Parented to the window overlay so it centres even when the editor is 176 px.
  Popup {
    id: colorPicker
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(396)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    onVisibleChanged: if (visible) {
      svCanvas.requestPaint()
      hueCanvas.requestPaint()
    }
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(10)

      Item {
        width: parent.width
        height: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Color Picker"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Button {
          width: Style.space(22)
          height: Style.space(20)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "×"
          fontSize: Style.font.bodySmall
          horizontalPadding: 0
          verticalPadding: 0
          onClicked: colorPicker.close()
        }
      }

      Row {
        spacing: Style.space(10)

        // Saturation (x) / value (y) square.
        Rectangle {
          id: svSquare
          width: Style.space(220)
          height: Style.space(220)
          radius: Style.space(3)
          clip: true
          border.width: 1
          border.color: Util.alpha(Commons.Color.foreground, 0.2)

          Canvas {
            id: svCanvas
            anchors.fill: parent
            onPaint: {
              var ctx = getContext("2d")
              var w = width
              var h = height
              ctx.clearRect(0, 0, w, h)
              var horizontal = ctx.createLinearGradient(0, 0, w, 0)
              horizontal.addColorStop(0, "#ffffff")
              horizontal.addColorStop(1, root.hueHex(root.pickerHue))
              ctx.fillStyle = horizontal
              ctx.fillRect(0, 0, w, h)
              var vertical = ctx.createLinearGradient(0, 0, 0, h)
              vertical.addColorStop(0, "rgba(0, 0, 0, 0)")
              vertical.addColorStop(1, "#000000")
              ctx.fillStyle = vertical
              ctx.fillRect(0, 0, w, h)
            }
          }

          Rectangle {
            width: Style.space(12)
            height: Style.space(12)
            radius: width / 2
            x: root.pickerSat * (svSquare.width - width)
            y: (1 - root.pickerVal) * (svSquare.height - height)
            color: "transparent"
            border.width: 2
            border.color: "#ffffff"

            Rectangle {
              anchors.centerIn: parent
              width: Style.space(8)
              height: Style.space(8)
              radius: width / 2
              color: "transparent"
              border.width: 1
              border.color: Qt.rgba(0, 0, 0, 0.55)
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.CrossCursor
            function pick(mouse) {
              root.pickerSat = root.clampUnit(mouse.x / width)
              root.pickerVal = 1 - root.clampUnit(mouse.y / height)
              root.syncPickerFields()
            }
            onPressed: function(mouse) { pick(mouse) }
            onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
          }
        }

        // Hue strip.
        Rectangle {
          id: hueStrip
          width: Style.space(18)
          height: Style.space(220)
          radius: Style.space(3)
          clip: true
          border.width: 1
          border.color: Util.alpha(Commons.Color.foreground, 0.2)

          Canvas {
            id: hueCanvas
            anchors.fill: parent
            onPaint: {
              var ctx = getContext("2d")
              var gradient = ctx.createLinearGradient(0, 0, 0, height)
              for (var i = 0; i <= 6; i++) {
                gradient.addColorStop(i / 6, root.hueHex(i * 60))
              }
              ctx.fillStyle = gradient
              ctx.fillRect(0, 0, width, height)
            }
          }

          Rectangle {
            x: -1
            width: hueStrip.width + 2
            height: Style.space(8)
            radius: Style.space(2)
            y: (root.pickerHue / 360) * (hueStrip.height - height)
            color: "transparent"
            border.width: 1
            border.color: "#ffffff"
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SizeVerCursor
            function pick(mouse) {
              root.pickerHue = root.clampUnit(mouse.y / height) * 360
              root.syncPickerFields()
            }
            onPressed: function(mouse) { pick(mouse) }
            onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
          }
        }

        // RGB, hex and preview.
        Column {
          width: Style.space(112)
          spacing: Style.space(5)

          Row {
            width: parent.width
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              text: "R"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.72)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: colorPickerRed
              objectName: "formatColorRed"
              width: parent.width - Style.space(14)
              font.pixelSize: Style.font.bodySmall
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              horizontalAlignment: TextInput.AlignHCenter
              validator: IntValidator { bottom: 0; top: 255 }
              inputMethodHints: Qt.ImhDigitsOnly
              onEditingFinished: root.commitPickerRgb()
              onAccepted: {
                root.commitPickerRgb()
                root.savePickerColour()
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              text: "G"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.72)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: colorPickerGreen
              objectName: "formatColorGreen"
              width: parent.width - Style.space(14)
              font.pixelSize: Style.font.bodySmall
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              horizontalAlignment: TextInput.AlignHCenter
              validator: IntValidator { bottom: 0; top: 255 }
              inputMethodHints: Qt.ImhDigitsOnly
              onEditingFinished: root.commitPickerRgb()
              onAccepted: {
                root.commitPickerRgb()
                root.savePickerColour()
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              text: "B"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.72)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: colorPickerBlue
              objectName: "formatColorBlue"
              width: parent.width - Style.space(14)
              font.pixelSize: Style.font.bodySmall
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              horizontalAlignment: TextInput.AlignHCenter
              validator: IntValidator { bottom: 0; top: 255 }
              inputMethodHints: Qt.ImhDigitsOnly
              onEditingFinished: root.commitPickerRgb()
              onAccepted: {
                root.commitPickerRgb()
                root.savePickerColour()
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              text: "#"
              textFormat: Text.PlainText
              color: Util.alpha(Commons.Color.foreground, 0.72)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: colorPickerHexField
              objectName: "formatColorHex"
              width: parent.width - Style.space(14)
              font.pixelSize: Style.font.bodySmall
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              placeholderText: "#e03e2d"
              // Live preview while a valid hex is typed, without rewriting the
              // field under the caret (syncPickerFields skips the focused one).
              onTextChanged: {
                if (!activeFocus) return
                var typed = MarkdownFormat.colourToHex(text)
                if (typed !== null) root.setPickerHex(typed)
              }
              onEditingFinished: root.commitPickerHex()
              onAccepted: {
                root.commitPickerHex()
                root.savePickerColour()
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.space(36)
            radius: Style.space(3)
            color: root.pickerColour
            border.width: 1
            border.color: Util.alpha(Commons.Color.foreground, 0.3)
          }
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.space(6)

        Button {
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          onClicked: colorPicker.close()
        }

        Button {
          id: colorPickerSave
          objectName: "formatColorSave"
          text: "Save"
          active: true
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          onClicked: root.savePickerColour()
        }
      }
    }
  }

  Popup {
    id: sizePopup
    width: Style.space(150)
    padding: Style.space(5)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: 1
      MenuButton { label: "Small"; onActivated: { root.invoke("size", "small"); sizePopup.close() } }
      MenuButton { label: "Normal"; onActivated: { root.invoke("size", "normal"); sizePopup.close() } }
      MenuButton { label: "Large"; onActivated: { root.invoke("size", "large"); sizePopup.close() } }
      MenuButton { label: "Extra large"; onActivated: { root.invoke("size", "xlarge"); sizePopup.close() } }
    }
  }

  Popup {
    id: headingPopup
    width: Style.space(150)
    padding: Style.space(5)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: 1
      MenuButton {
        objectName: "formatHeadingNormal"
        label: "Normal"
        onActivated: { root.invoke("heading", 0); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading1"
        label: "Heading 1"
        onActivated: { root.invoke("heading", 1); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading2"
        label: "Heading 2"
        onActivated: { root.invoke("heading", 2); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading3"
        label: "Heading 3"
        onActivated: { root.invoke("heading", 3); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading4"
        label: "Heading 4"
        onActivated: { root.invoke("heading", 4); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading5"
        label: "Heading 5"
        onActivated: { root.invoke("heading", 5); headingPopup.close() }
      }
      MenuButton {
        objectName: "formatHeading6"
        label: "Heading 6"
        onActivated: { root.invoke("heading", 6); headingPopup.close() }
      }
    }
  }

  Popup {
    id: insertPopup
    width: Style.space(150)
    padding: Style.space(5)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: 1
      MenuButton {
        objectName: "formatInsertDate"
        label: "Date"
        onActivated: root.insertDate()
      }
      MenuButton {
        objectName: "formatInsertTime"
        label: "Time"
        onActivated: root.insertTime()
      }
      MenuButton {
        id: insertEmojiItem
        objectName: "formatInsertEmoji"
        label: "Emoji…"
        onActivated: {
          insertPopup.close()
          root.openEmojiPopover()
        }
      }
      MenuButton {
        objectName: "formatInsertAttach"
        label: "Attach file…"
        onActivated: {
          insertPopup.close()
          root.invoke("attach", "")
        }
      }
      MenuButton {
        objectName: "formatInsertNoteLink"
        label: "Note link…"
        onActivated: {
          insertPopup.close()
          root.openNoteLink()
        }
      }
    }
  }

  Popup {
    id: linkPopup
    width: Style.space(270)
    padding: Style.space(8)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Text {
        text: "Link URL"
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: linkField
        objectName: "formatLinkField"
        width: parent.width
        placeholderText: "https://example.com"
        font.pixelSize: Style.font.bodySmall
        onAccepted: if (linkField.text.trim() !== "") {
          root.invoke("link", linkField.text.trim())
          linkPopup.close()
        }
      }

      Row {
        spacing: Style.space(5)
        anchors.right: parent.right

        Button {
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          onClicked: linkPopup.close()
        }
        Button {
          id: linkApply
          objectName: "formatLinkApply"
          text: "Apply"
          active: linkField.text.trim() !== ""
          enabled: linkField.text.trim() !== ""
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          onClicked: {
            root.invoke("link", linkField.text.trim())
            linkPopup.close()
          }
        }
      }
    }
  }

  Popup {
    id: noteLinkPopup
    objectName: "noteLinkPopup"
    width: Style.space(270)
    padding: Style.space(8)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Text {
        text: "Note link"
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: noteLinkField
        objectName: "noteLinkField"
        width: parent.width
        placeholderText: "Search notes…"
        font.pixelSize: Style.font.bodySmall
        onTextChanged: root.noteLinkQuery = text
        onAccepted: {
          // An empty field is a no-op: the engine rejects an empty title too.
          if (text.trim() === "" || root.noteLinkMatches.length === 0) return
          root.insertNoteLink(root.noteLinkMatches[0])
        }
      }

      Item {
        width: parent.width
        height: Style.space(150)

        ListView {
          id: noteLinkList
          anchors.fill: parent
          clip: true
          visible: root.noteLinkMatches.length > 0
          model: root.noteLinkMatches
          boundsBehavior: Flickable.StopAtBounds

          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
          }

          delegate: Rectangle {
            required property string modelData

            width: noteLinkList.width
            height: Style.space(24)
            color: noteLinkMouse.containsMouse
              ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
              : "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData
              elide: Text.ElideRight
              textFormat: Text.PlainText
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: noteLinkMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.insertNoteLink(modelData)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.noteLinkMatches.length === 0
          text: "No notes found"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Popup {
    id: emojiPopup
    objectName: "emojiPopup"
    width: Style.space(280)
    padding: Style.space(8)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      TextField {
        id: emojiSearch
        objectName: "emojiSearch"
        width: parent.width
        placeholderText: "Search emoji…"
        font.pixelSize: Style.font.bodySmall
        onTextChanged: root.emojiQuery = text
        onAccepted: root.insertFirstEmoji()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            event.accepted = true
            emojiPopup.close()
          }
        }
      }

      Item {
        width: parent.width
        height: Style.space(206)

        GridView {
          id: emojiGrid
          objectName: "emojiGrid"
          anchors.fill: parent
          clip: true
          cellWidth: width / 8
          cellHeight: Style.space(30)
          model: root.emojiMatches
          boundsBehavior: Flickable.StopAtBounds

          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
          }

          delegate: Rectangle {
            id: emojiCell
            required property var modelData
            required property int index

            objectName: "formatEmoji" + index
            width: emojiGrid.cellWidth
            height: emojiGrid.cellHeight
            radius: Style.space(3)
            color: emojiHit.containsMouse
              ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
              : "transparent"

            Text {
              anchors.centerIn: parent
              text: emojiCell.modelData.glyph
              textFormat: Text.PlainText
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: emojiHit
              objectName: "formatEmojiHit" + emojiCell.index
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.insertEmoji(emojiCell.modelData.glyph)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.emojiMatches.length === 0
          text: "No emoji found"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Popup {
    id: tablePopup
    width: Style.space(168)
    padding: Style.space(7)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(4)

      Text {
        text: root.tableHoverRow >= 0
          ? (root.tableHoverRow + 1) + " × " + (root.tableHoverCol + 1) + " + header"
          : "Rows × columns"
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Column {
        spacing: Style.space(2)
        Repeater {
          model: 8
          Row {
            required property int index
            spacing: Style.space(2)
            Repeater {
              model: 8
              Rectangle {
                required property int index
                width: Style.space(15)
                height: Style.space(15)
                radius: Style.space(2)
                color: index <= root.tableHoverCol && parent.index <= root.tableHoverRow
                  ? Util.alpha(Commons.Color.accent, 0.5)
                  : Util.alpha(Commons.Color.foreground, 0.07)
                border.width: 1
                border.color: Util.alpha(Commons.Color.foreground, 0.16)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: {
                    root.tableHoverRow = parent.parent.index
                    root.tableHoverCol = index
                  }
                  onClicked: {
                    root.invoke("table", {
                      rows: parent.parent.index + 1,
                      columns: index + 1
                    })
                    tablePopup.close()
                  }
                }
              }
            }
          }
        }
      }

      Text {
        text: "Header row included"
        color: Util.alpha(Commons.Color.foreground, 0.34)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---------------------------------------------------------------- components

  component SwatchCell: Rectangle {
    id: cell
    property string swatch: "#000000"
    property bool active: false
    signal picked()

    width: Style.space(24)
    height: Style.space(22)
    radius: Style.space(3)
    color: cell.swatch
    border.width: 1
    border.color: cell.active
      ? Commons.Color.accent
      : Util.alpha(Commons.Color.foreground, 0.22)

    MouseArea {
      id: cellMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: cell.picked()
    }

    Rectangle {
      anchors.fill: parent
      radius: cell.radius
      color: Util.alpha(Commons.Color.foreground, cellMouse.containsMouse ? 0.12 : 0)
    }

    Text {
      anchors.centerIn: parent
      visible: cell.active
      text: "✓"
      textFormat: Text.PlainText
      color: root.contrastColour(cell.swatch)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component FmtButton: Button {
    id: formatButton
    property string glyph: ""
    property string tip: ""
    signal activated()

    text: ""
    iconText: glyph
    iconSize: Style.font.bodySmall
    tooltipText: tip
    width: Style.space(23)
    height: Style.space(23)
    horizontalPadding: 0
    verticalPadding: 0
    focusable: false
    enabled: root.available
    onClicked: formatButton.activated()
  }

  component Divider: Item {
    objectName: "formatDivider"
    width: 1
    height: Style.space(23)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: Style.space(15)
      color: Util.alpha(Commons.Color.foreground, 0.13)
    }
  }

  component MenuButton: BorderSurface {
    id: menuButton
    property string label: ""
    signal activated()

    width: parent ? parent.width : 0
    height: Style.space(26)
    color: menuMouse.containsMouse
      ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
      : "transparent"
    borderSpec: Border.none
    radius: Style.cornerRadius

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(7)
      anchors.verticalCenter: parent.verticalCenter
      text: menuButton.label
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: menuMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: menuButton.activated()
    }
  }
}
