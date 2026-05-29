import { Controller } from "@hotwired/stimulus"

// Stimulus controller for the conversation drawer.
//
// The drawer is rendered hidden in the dashboard layout. When the user
// clicks a feed card, Turbo loads the channel thread into the inner
// <turbo-frame id="thread_drawer">. We watch that frame for content
// changes via MutationObserver — any time it goes from empty to non-empty,
// we open the drawer; when its inner HTML is cleared, we close.
//
// Close paths: backdrop click, Escape key, an explicit close button
// (which empties the frame).
export default class extends Controller {
  static targets = ["root", "panel", "backdrop", "frame", "compose"]
  static classes = ["open", "closed"]

  connect() {
    this.boundOnKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.boundOnKeydown)

    // Open whenever the frame loads new content.
    this.observer = new MutationObserver(() => {
      if (this.frameHasContent()) this.open()
      else this.hide()
    })
    this.observer.observe(this.frameTarget, { childList: true, subtree: false })
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundOnKeydown)
    if (this.observer) this.observer.disconnect()
  }

  frameHasContent() {
    // turbo-frame leaves a comment node when empty; treat that as empty.
    for (const node of this.frameTarget.childNodes) {
      if (node.nodeType === Node.ELEMENT_NODE) return true
    }
    return false
  }

  open() {
    this.rootTarget.classList.remove("hidden")
    // Force a layout flush before adding the open class so the transition runs.
    void this.rootTarget.offsetWidth
    this.panelTarget.classList.remove("translate-x-full")
    this.panelTarget.classList.add("translate-x-0")
    this.backdropTarget.classList.remove("opacity-0")
    this.backdropTarget.classList.add("opacity-100")
    document.body.classList.add("overflow-hidden")
    this._updateComposeUrl()
  }

  _updateComposeUrl() {
    if (!this.hasComposeTarget) return
    const src = this.frameTarget.src || ""
    // Extract channel id from /channels/:id — the compose controller uses this
    // to build the POST URL.
    const match = src.match(/\/channels\/([^?#]+)/)
    const channelId = match ? decodeURIComponent(match[1]) : ""
    this.composeTarget.dataset.composeUrlValue =
      channelId ? `/channels/${encodeURIComponent(channelId)}/messages` : ""
    // Dispatch a custom event so the compose controller can re-read its value.
    this.composeTarget.dispatchEvent(new CustomEvent("compose:channel-changed", { bubbles: false }))
  }

  hide() {
    this.panelTarget.classList.remove("translate-x-0")
    this.panelTarget.classList.add("translate-x-full")
    this.backdropTarget.classList.remove("opacity-100")
    this.backdropTarget.classList.add("opacity-0")
    document.body.classList.remove("overflow-hidden")
    // Wait for the transition to finish before hiding the root.
    setTimeout(() => {
      if (!this.frameHasContent()) this.rootTarget.classList.add("hidden")
    }, 220)
  }

  // Explicit close: empty the frame, which fires the observer.
  close(event) {
    if (event) event.preventDefault()
    this.frameTarget.innerHTML = ""
    // Also clean up the URL so a refresh doesn't reopen the drawer.
    if (window.history && window.location.hash !== "") {
      window.history.replaceState({}, "", window.location.pathname + window.location.search)
    }
  }

  onKeydown(e) {
    if (e.key === "Escape" && this.frameHasContent()) {
      e.preventDefault()
      this.close()
    }
  }
}
