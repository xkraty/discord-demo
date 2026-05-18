import { Controller } from "@hotwired/stimulus"

// Click handler on each dashboard feed card. Opens the per-channel
// conversation drawer by navigating the #thread_drawer Turbo Frame to
// /channels/:discord_channel_id.
//
// We don't wrap the card in an <a> because the card contains real <a>
// elements (images, embed links, reply hooks) and nested anchors are
// invalid HTML. Instead this handler watches for clicks anywhere on the
// card and bails out when the click target is or sits under an existing
// <a>, <button>, <input>, <textarea>, or <img>.
export default class extends Controller {
  static values = { url: String }

  maybeOpen(event) {
    // Don't hijack clicks on real interactive children.
    if (event.target.closest("a, button, input, textarea, img, select, label")) return
    // Modifier-clicks: let the browser do whatever it would natively (eg
    // copy-link contextually). Without a real <a> there's nothing to do,
    // but at least don't open the drawer surprisingly.
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    if (!this.hasUrlValue || this.urlValue === "") return

    event.preventDefault()
    // Use the Turbo Frame mechanism: setting src on the target frame loads
    // it in place without a full navigation.
    const frame = document.getElementById("thread_drawer")
    if (frame) {
      frame.src = this.urlValue
    }
  }
}
