import { Controller } from "@hotwired/stimulus"

// Polls the progress endpoint while a run is in flight and swaps the rendered body in.
//
// HTTP rather than a socket on purpose: the answer changes on the order of seconds, a
// missed update costs nothing, and the endpoint is conditional -- an unchanged
// representation returns 304 and the server never reads the journal.
export default class extends Controller {
  static targets = ["body"]
  static values = {
    url: String,
    interval: { type: Number, default: 5000 }
  }

  connect() {
    this.failures = 0
    this.scheduleNext()
  }

  disconnect() {
    this.cancel()
  }

  cancel() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  // Only schedules while the rendered body says there is something left to learn. The
  // server decides that, not the client: it knows the lifecycle, and a client guessing
  // from a label would keep polling a finished run forever.
  scheduleNext() {
    this.cancel()
    if (!this.shouldPoll()) return

    this.timer = setTimeout(() => this.refresh(), this.delay())
  }

  shouldPoll() {
    if (!this.hasBodyTarget) return false
    return this.bodyTarget.dataset.poll === "true"
  }

  // Backs off after consecutive failures instead of hammering a server that is already
  // struggling, and gives up entirely after a run of them rather than polling forever
  // in a tab nobody is watching.
  delay() {
    if (this.failures === 0) return this.intervalValue
    return Math.min(this.intervalValue * Math.pow(2, this.failures), 60000)
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/html" },
        credentials: "same-origin"
      })

      if (response.status === 304) {
        // Nothing changed. Not a failure: the conditional response is the point.
        this.failures = 0
        this.scheduleNext()
        return
      }

      if (!response.ok) {
        this.onFailure()
        return
      }

      const html = await response.text()
      this.failures = 0
      this.replaceBody(html)

      // A finished run stops the loop, and the freshly rendered body is what says so.
      this.scheduleNext()
    } catch (error) {
      this.onFailure()
    }
  }

  onFailure() {
    this.failures += 1
    if (this.failures >= 5) {
      // The card keeps showing the last thing we knew, which is honest: it is stale,
      // not wrong, and reloading the page recovers.
      this.cancel()
      return
    }
    this.scheduleNext()
  }

  replaceBody(html) {
    if (!this.hasBodyTarget) return

    const template = document.createElement("template")
    template.innerHTML = html.trim()
    const next = template.content.firstElementChild
    if (!next) return

    this.bodyTarget.replaceWith(next)
  }
}
