import { Controller } from "@hotwired/stimulus"

// Handles the message compose bar in the channel drawer.
//
// The URL to POST to is supplied by the parent thread-drawer controller via
// data-compose-url-value (updated whenever the open channel changes).
// The controller listens for the "compose:channel-changed" event to reset its
// state when switching channels.
//
// Send shortcuts: Enter (without Shift) or Cmd/Ctrl+Enter.
export default class extends Controller {
  static targets = ["input", "button", "status"]
  static values  = { url: String }

  connect() {
    this._onChannelChanged = this._reset.bind(this)
    this.element.addEventListener("compose:channel-changed", this._onChannelChanged)
    this._autoResize()
  }

  disconnect() {
    this.element.removeEventListener("compose:channel-changed", this._onChannelChanged)
  }

  urlValueChanged() {
    const enabled = this.urlValue !== ""
    this.inputTarget.disabled  = !enabled
    this.buttonTarget.disabled = !enabled
    if (!enabled) this.inputTarget.placeholder = "Select a conversation to reply…"
    else          this.inputTarget.placeholder = "Message…"
  }

  onInput() {
    this._autoResize()
  }

  onKeydown(e) {
    // Enter without Shift sends; Shift+Enter adds a newline.
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault()
      this.send()
    }
  }

  async send() {
    const body = this.inputTarget.value.trim()
    if (!body || !this.urlValue) return

    this._setSending(true)

    try {
      const resp = await fetch(this.urlValue, {
        method:  "POST",
        headers: {
          "Content-Type":  "application/x-www-form-urlencoded",
          "X-CSRF-Token":  this._csrfToken(),
          "Accept":        "application/json",
        },
        body: new URLSearchParams({ body }),
      })

      if (resp.ok) {
        this.inputTarget.value = ""
        this._autoResize()
        this._showStatus("Queued — extension will deliver shortly.", false)
      } else {
        const data = await resp.json().catch(() => ({}))
        this._showStatus((data.errors || []).join("; ") || "Failed to queue message.", true)
      }
    } catch {
      this._showStatus("Network error — please try again.", true)
    } finally {
      this._setSending(false)
    }
  }

  // ── private ──────────────────────────────────────────────────────────────

  _setSending(sending) {
    this.inputTarget.disabled  = sending
    this.buttonTarget.disabled = sending
    this.buttonTarget.setAttribute("aria-busy", sending)
  }

  _showStatus(text, isError) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.remove("hidden", "text-slate-400", "text-red-500")
    this.statusTarget.classList.add(isError ? "text-red-500" : "text-slate-400")
    clearTimeout(this._statusTimer)
    this._statusTimer = setTimeout(() => {
      this.statusTarget.classList.add("hidden")
    }, 4000)
  }

  _reset() {
    this.inputTarget.value = ""
    this._autoResize()
    this.statusTarget.classList.add("hidden")
    // Re-run urlValueChanged so enabled state reflects the new channel.
    this.urlValueChanged()
  }

  _autoResize() {
    const el = this.inputTarget
    el.style.height = "auto"
    el.style.height = Math.min(el.scrollHeight, 160) + "px"
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
