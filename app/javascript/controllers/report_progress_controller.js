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
    this.finished = false
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
      const stillRunning = this.replaceBody(html)

      // Read from the HTML we just received, not from the DOM after replacing it: the
      // target reference can still point at the element we swapped out.
      if (!stillRunning) {
        // Everything OUTSIDE this card was rendered server-side for a run in flight --
        // Key Statistics in particular says "Pending" because results are not written
        // until the journal is ingested. Swapping only the card would leave a finished
        // report reading Pending beside a card that says otherwise, which is the exact
        // confusion this feature exists to remove. Reload once so the whole page
        // re-renders with the real figures.
        this.finish()
        return
      }

      this.scheduleNext()
    } catch (error) {
      this.onFailure()
    }
  }

  // Guarded: replaceBody can fire more than once in flight, and a reload loop would
  // be worse than a stale card.
  finish() {
    if (this.finished) return
    this.finished = true
    this.cancel()
    window.location.reload()
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

  // Returns whether the body it installed still wants polling.
  replaceBody(html) {
    if (!this.hasBodyTarget) return false

    const template = document.createElement("template")
    template.innerHTML = html.trim()
    const next = template.content.firstElementChild
    if (!next) return this.shouldPoll()

    this.bodyTarget.replaceWith(next)
    this.bodyTarget = next
    return next.dataset.poll === "true"
  }
}
