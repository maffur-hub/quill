import QtQuick
import Quickshell
import Quickshell.Io

// A note over the size limit opens read-only. It was also unwatched, so the
// reader never learned that the file had changed and never noticed when it
// shrank back under the limit. This case grows a note past the limit, opens
// it, shrinks it from outside and expects the editor to adopt it.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""
  readonly property string notePath: dataRoot + "/notes/" + noteId

  readonly property string smallText: "# Shrunk\n\nnow editable again\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    var component = Qt.createComponent(Qt.resolvedUrl("../../Library.qml"))
    if (component.status !== Component.Ready) {
      h.check("the library can be created", false, "component is not ready")
      h.done()
      return
    }
    library = component.createObject(test, {
      dataRoot: test.dataRoot,
      storePath: test.storePath,
      joplinSyncPath: "",
      width: 1000,
      height: 700
    })
    if (!library) {
      h.check("the library can be created", false)
      h.done()
      return
    }
    step = 1
    tick.start()
  }

  function fail(message) {
    harness.check("large-note harness completed", false, message)
    harness.done()
  }

  function findByName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = []
    var i
    if (item.children) {
      for (i = 0; i < item.children.length; i++) kids.push(item.children[i])
    }
    try {
      if (item.data) {
        for (i = 0; i < item.data.length; i++) kids.push(item.data[i])
      }
    } catch (error) {}
    if (item.contentItem) kids.push(item.contentItem)
    if (item.item) kids.push(item.item)
    for (i = 0; i < kids.length; i++) {
      var hit = test.findByName(kids[i], name)
      if (hit) return hit
    }
    return null
  }

  function hasNote() {
    var list = test.library ? (test.library.notes || []) : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === test.noteId) return true
    }
    return false
  }

  // Written straight into the data root: the store itself refuses to create a
  // note this large, which is the whole reason the window has to cope.
  function grow() {
    growProcess.command = ["sh", "-c",
      "head -c 1200000 /dev/zero | tr '\\0' 'x' > \"$1\"", "quill", test.notePath]
    growProcess.running = true
  }

  function shrink() {
    shrinkProcess.command = ["sh", "-c",
      "printf '%s' \"$1\" > \"$2\"", "quill", test.smallText, test.notePath]
    shrinkProcess.running = true
  }

  function advance() {
    ticks += 1
    if (ticks > 90) return fail("timed out in step " + step)

    if (step === 1) {
      if (!library.settingsLoaded) return
      if (!test.hasNote()) {
        if (!test.refreshed && ticks > 20) {
          test.refreshed = true
          library.refreshAll()
        }
        return
      }
      test.grow()
      step = 2
      return
    }

    if (step === 2) {
      if (growProcess.running) return
      // The library selects the first note by itself when it finishes loading,
      // so the seeded note may already be open (and loaded) before this case
      // grows it. selectNote is a no-op then and nothing re-reads the file, so
      // ask for a fresh load instead.
      if (String(library.selectedId) === noteId) {
        if (!library.loadingNote) library.loadNote()
      } else {
        library.selectNote(test.noteId)
      }
      step = 3
      return
    }

    if (step === 3) {
      if (String(library.selectedId) !== noteId) return
      if (!library.tooLarge) return
      harness.check("a note over the size limit opens read-only",
        !library.loaded, "loaded=" + library.loaded)
      editor = findByName(library, "markdownEditor")
      if (!editor) return fail("the editor is not in the library")
      test.shrink()
      step = 4
      return
    }

    if (step === 4) {
      if (shrinkProcess.running) return
      if (!library.loaded) return
      harness.check("the window adopts a read-only note that shrank",
        String(editor.text) === test.smallText, JSON.stringify(editor.text))
      harness.check("the note is editable again", library.tooLarge === false
        && String(library.statusText).indexOf("too large") < 0,
        String(library.statusText))
      harness.done()
      step = 5
    }
  }

  Timer {
    id: tick
    interval: 120
    repeat: true
    onTriggered: test.advance()
  }

  Process { id: growProcess }
  Process { id: shrinkProcess }
}
