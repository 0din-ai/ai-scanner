import { Controller } from "@hotwired/stimulus"

const DEFAULT_INTERVAL_MS = 30000

export default class extends Controller {
  static values = {
    url: String,
    interval: Number
  }

  connect() {
    if (!this.hasUrlValue) return

    this.inFlight = false
    this.refreshLease()
    this.timer = window.setInterval(() => this.refreshLease(), this.intervalMs)
  }

  disconnect() {
    if (this.timer) {
      window.clearInterval(this.timer)
      this.timer = null
    }
  }

  get intervalMs() {
    if (this.hasIntervalValue && this.intervalValue > 0) {
      return this.intervalValue
    }

    return DEFAULT_INTERVAL_MS
  }

  async refreshLease() {
    if (this.inFlight) return

    this.inFlight = true

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Accept": "text/plain",
          "X-CSRF-Token": this.csrfToken(),
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })

      if (!response.ok) {
        console.warn(`Debug stream lease refresh failed with status ${response.status}`)
      }
    } catch (error) {
      console.warn("Debug stream lease refresh failed", error)
    } finally {
      this.inFlight = false
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
