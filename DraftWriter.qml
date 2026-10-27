import Quickshell
import Quickshell.Io

// Serialized crash-draft writer. FileView writes asynchronously and has no
// delete method, so the store owns draft detection/removal; this component
// only ever writes one draft file at a time, in arrival order.
//
// `enqueue(path, text)` replaces a queued job for the same path and appends
// otherwise. `drop(path)` forgets queued jobs (an in-flight write cannot be
// cancelled). Failed writes are reported and not retried automatically.
FileView {
  id: root

  property var queue: []
  property bool busy: false
  property string activePath: ""

  signal wrote(string path)
  signal failed(string path, string error)

  atomicWrites: true
  blockAllReads: true
  printErrors: false

  function enqueue(path, text) {
    var target = String(path || "")
    if (target === "") return
    var job = { path: target, text: String(text || "") }
    for (var i = 0; i < root.queue.length; i++) {
      if (root.queue[i].path === target) {
        root.queue.splice(i, 1, job)
        root.pump()
        return
      }
    }
    root.queue.push(job)
    root.pump()
  }

  function drop(path) {
    var target = String(path || "")
    if (target === "") return
    for (var i = root.queue.length - 1; i >= 0; i--) {
      if (root.queue[i].path === target) root.queue.splice(i, 1)
    }
  }

  function pump() {
    if (root.busy || root.queue.length === 0) return
    var job = root.queue.shift()
    root.busy = true
    root.activePath = job.path
    // FileView applies setText to the path current at write time, so never
    // change the path while a write is in flight.
    root.path = job.path
    root.setText(job.text)
  }

  function finish(saved, error) {
    var path = root.activePath
    root.activePath = ""
    root.busy = false
    if (saved) root.wrote(path)
    else root.failed(path, error === undefined ? "Could not write draft" : String(error))
    root.pump()
  }

  onSaved: root.finish(true)
  onSaveFailed: function(error) { root.finish(false, error) }
}
