.pragma library

// Qt clears a popup's parent item when it closes, and that permanently breaks
// the declarative `parent: Overlay.overlay` binding: the next open has no
// parent item and silently paints nothing. Every open path therefore
// re-attaches the popup to the window overlay first. The overlay is passed in
// because a QML library cannot read the attached Overlay.overlay property.
function anchor(popup, overlay) {
  if (!popup || !overlay) return
  if (popup.parent !== overlay) popup.parent = overlay
}
