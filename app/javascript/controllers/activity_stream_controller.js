import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "summary", "details", "button", "buttonLabel" ]

  connect() {
    this.expanded = false
    this.sync()
  }

  toggle() {
    this.expanded = !this.expanded
    this.sync()

    if (this.expanded) {
      this.focusDetails()
    }
  }

  sync() {
    if (!this.hasDetailsTarget || !this.hasButtonTarget || !this.hasButtonLabelTarget) return

    this.detailsTarget.classList.toggle("hidden", !this.expanded)
    this.buttonTarget.setAttribute("aria-expanded", this.expanded.toString())
    this.buttonLabelTarget.textContent = this.expanded ? "Hide activity" : "View activity"
  }

  focusDetails() {
    if (!this.hasDetailsTarget) return

    const focusTarget = this.detailsTarget.querySelector("[data-activity-stream-focus-target]")
    if (!focusTarget) return

    requestAnimationFrame(() => focusTarget.focus({ preventScroll: true }))
  }
}
