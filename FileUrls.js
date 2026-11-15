// Turn a local path into a file:// URL.
//
// Qt.openUrlExternally and Image.source want a URL. A bare absolute path
// mostly works until it contains a space, a parenthesis, '#' or '?', and then
// the opener either fails or truncates the name. Percent escapes that a link
// already carries (`My%20Notes`) are decoded first so they are not encoded
// twice. Scheme-bearing values are returned untouched, because callers use
// this for destinations that may already be http(s).
function fileUrl(path) {
  var value = String(path === undefined || path === null ? "" : path)
  if (value === "") return ""
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return value
  try {
    value = decodeURI(value)
  } catch (error) {
    // A lone '%' is a legal file name; keep it verbatim and let encodeURI
    // escape it below.
  }
  var encoded
  try {
    encoded = encodeURI(value)
  } catch (error) {
    encoded = value
  }
  // '#' and '?' survive encodeURI but would be read as a fragment or a query.
  encoded = encoded.replace(/#/g, "%23").replace(/\?/g, "%3F")
  return "file://" + encoded
}
