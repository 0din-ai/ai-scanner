import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query", "row", "group", "emptyState"]

  connect() {
    this.filter()
  }

  rowTargetConnected(row) {
    this.applyRow(row)
    this.updateEmptyStates()
  }

  filter() {
    this.rowTargets.forEach((row) => {
      this.applyRow(row)
    })

    this.updateEmptyStates()
  }

  clearQuery() {
    if (!this.hasQueryTarget) return

    this.queryTarget.value = ""
    this.filter()
  }

  applyRow(row) {
    const matchesQuery = this.query === "" || row.textContent.toLowerCase().includes(this.query)

    row.dataset.debugStreamFilterMatch = matchesQuery ? "true" : "false"
    this.applyVisibility(row)
  }

  // Visibility composition note:
  // Rows are visible iff data-debug-stream-filter-match !== "false" AND
  // data-log-viewer-filter-match !== "false". Both this controller and
  // log_viewer_controller.js evaluate the same predicate. If a third
  // visibility axis is ever added, both files must update in lockstep.
  applyVisibility(row) {
    row.style.display = this.rowVisible(row) ? "" : "none"
  }

  updateEmptyStates() {
    this.groupTargets.forEach((group) => {
      const emptyState = group.querySelector('[data-debug-stream-filter-target~="emptyState"]')

      if (!emptyState) return

      const rows = Array.from(group.querySelectorAll('[data-debug-stream-filter-target~="row"]'))
      const hasVisibleRows = rows.some((row) => this.rowVisible(row))
      const hasActiveFilter =
        this.query !== "" || rows.some((row) => row.dataset.logViewerFilterMatch === "false")

      emptyState.hidden = rows.length === 0 || hasVisibleRows || !hasActiveFilter
    })
  }

  rowVisible(row) {
    const matchesStreamFilter = row.dataset.debugStreamFilterMatch !== "false"
    const matchesLogFilter = row.dataset.logViewerFilterMatch !== "false"

    return matchesStreamFilter && matchesLogFilter
  }

  get query() {
    if (!this.hasQueryTarget) return ""

    return this.queryTarget.value.trim().toLowerCase()
  }
}
