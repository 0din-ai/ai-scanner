import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "search"]

  filter(event) {
    const type = event.currentTarget.dataset.filterType

    this.lines.forEach(line => {
      // Hide only the opposite type — info/emoji/module/progress/detector lines stay visible.
      const hide =
        (type === 'pass' && line.classList.contains('fail-line')) ||
        (type === 'fail' && line.classList.contains('pass-line'))

      line.dataset.logViewerStatusMatch = hide ? 'false' : 'true'
      this.updateLogViewerMatch(line)
    })

    this.notifyFilterChange()
  }

  resetFilter() {
    if (this.hasSearchTarget) {
      this.searchTarget.value = ''
    }

    this.lines.forEach(line => {
      line.dataset.logViewerStatusMatch = 'true'
      line.dataset.logViewerSearchMatch = 'true'
      this.updateLogViewerMatch(line)
      line.style.backgroundColor = ''
    })

    this.notifyFilterChange()
    // Fired after notifyFilterChange so cross-panel listeners can also clear their query state.
    this.element.dispatchEvent(new CustomEvent('log-viewer:reset', { bubbles: true }))
  }

  search() {
    const query = this.searchTarget.value.toLowerCase()

    this.lines.forEach(line => {
      const matchesSearch = query === '' || line.textContent.toLowerCase().includes(query)
      line.dataset.logViewerSearchMatch = matchesSearch ? 'true' : 'false'
      this.updateLogViewerMatch(line)
      line.style.backgroundColor = query !== '' && matchesSearch ? 'rgba(255, 255, 0, 0.1)' : ''
    })

    this.notifyFilterChange()
  }

  updateLogViewerMatch(line) {
    const matchesStatusFilter = line.dataset.logViewerStatusMatch !== 'false'
    const matchesSearchFilter = line.dataset.logViewerSearchMatch !== 'false'

    line.dataset.logViewerFilterMatch = matchesStatusFilter && matchesSearchFilter ? 'true' : 'false'
    this.applyVisibility(line)
  }

  applyVisibility(line) {
    const matchesStreamFilter = line.dataset.debugStreamFilterMatch !== 'false'
    const matchesLogFilter = line.dataset.logViewerFilterMatch !== 'false'

    line.style.display = matchesStreamFilter && matchesLogFilter ? '' : 'none'
  }

  notifyFilterChange() {
    this.element.dispatchEvent(new CustomEvent('log-viewer:filter-change', { bubbles: true }))
  }

  get lines() {
    return Array.from(this.contentTarget.querySelectorAll('.log-line'))
  }
}
