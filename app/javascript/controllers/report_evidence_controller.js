import { Controller } from "@hotwired/stimulus"

// Evidence tab: opens one attempt's prompt, response and scoring evidence in a
// drawer beside the list.
//
// A drawer rather than a page because reading evidence is comparative -- you
// check one attempt against the next -- so the list, the active filter and the
// scroll position all have to survive. ArrowUp/ArrowDown step through the
// report's whole filtered order, not just the rendered page: the server sends
// each attempt's neighbours with it, so stepping crosses a page boundary
// without the reader paging or losing the drawer.
export default class extends Controller {
  static targets = ["drawer", "panel", "content", "title", "position", "prev", "next", "row"]
  static values = {
    attemptUrl: String,
    selectedProbeResult: String,
    selectedIndex: String,
    filter: String,
    query: String
  }

  connect() {
    this.onKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    this.openFromLocation()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  // Deep link: ?probe_result_id=<id>&attempt_index=<n> opens that attempt on
  // load, so a link lands on the evidence rather than near it. The index is
  // into the stored attempts array, so it stays valid even where a malformed
  // row is skipped in the list. Not the uuid -- a uuid names one evaluated
  // item whose start and completion rows collapse to a single row (see
  // ProbeResult#displayed_attempt_key), and rows recorded without one stay
  // distinct, so a uuid does not address a row uniquely.
  //
  // The selection comes from the server rather than from window.location
  // because the server also resolved which page the row is on -- reading the
  // URL here would only ever find rows in the rendered slice.
  openFromLocation() {
    if (!this.hasSelectedProbeResultValue || !this.selectedProbeResultValue) return
    if (!this.hasSelectedIndexValue || this.selectedIndexValue === "") return

    this.load({
      probeResultId: this.selectedProbeResultValue,
      attemptIndex: this.selectedIndexValue
    })
  }

  open(event) {
    // Space scrolls the page by default when a row has focus.
    if (event.type === "keydown") event.preventDefault()

    const row = event.currentTarget
    return this.load({
      probeResultId: row.dataset.probeResultId,
      attemptIndex: row.dataset.attemptIndex
    })
  }

  // An attempt is addressed by identity rather than by a row element, because
  // the list is paged and the attempt being stepped to is often not rendered.
  async load(coordinate) {
    // Arrowing quickly leaves several fetches in flight. Only the newest may
    // write to the drawer -- otherwise a slow earlier response lands last and
    // shows one attempt's evidence under another attempt's header.
    const token = (this.requestToken || 0) + 1
    this.requestToken = token

    this.current = coordinate
    this.neighbours = null
    this.drawerTarget.classList.remove("hidden")
    this.contentTarget.innerHTML = '<p class="text-sm text-contentSecondary font-sans">Loading evidence...</p>'
    // Nothing to step to until the response says what the neighbours are, and
    // the previous attempt's position would describe the wrong one -- including
    // if the request fails and the drawer keeps showing the error.
    this.setStepEnabled(false, false)
    if (this.hasPositionTarget) this.positionTarget.textContent = ""
    // The title names the probe too, and an error left under the previous
    // attempt's heading reads as that attempt having failed.
    if (this.hasTitleTarget) this.titleTarget.textContent = "Attempt"
    this.markActiveRow()

    if (!this.lastFocused) this.lastFocused = document.activeElement
    this.panelTarget.focus()

    const url = new URL(this.attemptUrlValue, window.location.origin)
    url.searchParams.set("probe_result_id", coordinate.probeResultId)
    url.searchParams.set("attempt_index", coordinate.attemptIndex)
    // The reader is stepping through the list in front of them, so the
    // neighbours have to be computed under the same filter and search.
    if (this.hasFilterValue && this.filterValue) url.searchParams.set("filter", this.filterValue)
    if (this.hasQueryValue && this.queryValue) url.searchParams.set("q", this.queryValue)

    try {
      const response = await fetch(url, { headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const body = await response.text()
      if (token !== this.requestToken) return

      this.contentTarget.innerHTML = body
      this.readNeighbours()
      this.updateNav()
    } catch (error) {
      if (token !== this.requestToken) return

      console.error("[report-evidence] Failed to load attempt evidence:", error)
      this.contentTarget.innerHTML =
        '<p class="text-sm text-red-400 font-sans">Failed to load this attempt. Please try again.</p>'
    }
  }

  close() {
    this.drawerTarget.classList.add("hidden")
    this.current = null
    this.neighbours = null
    // Otherwise the row stays highlighted with no drawer to explain why.
    this.markActiveRow()
    if (this.lastFocused) {
      this.lastFocused.focus()
      this.lastFocused = null
    }
  }

  previous() {
    this.step(-1)
  }

  next() {
    this.step(1)
  }

  // The step targets come from the server, which owns the de-duplicated,
  // filtered order of the whole report. Walking the rendered rows instead
  // stopped dead at the page boundary: a 60-attempt report read "25 of 25"
  // and would not cross to page 2 without closing the drawer and paging.
  step(delta) {
    if (!this.neighbours) return

    const target = delta < 0 ? this.neighbours.previous : this.neighbours.next
    if (target) this.load(target)
  }

  // The metadata rides on the fragment the server just rendered rather than a
  // second request, so the neighbours can never describe a different attempt
  // from the evidence beside them.
  readNeighbours() {
    const meta = this.contentTarget.querySelector("[data-evidence-total]")
    if (!meta) {
      this.neighbours = null
      return
    }

    const coordinate = (side) => {
      const id = meta.dataset[`evidence${side}ProbeResultId`]
      if (!id) return null

      return { probeResultId: id, attemptIndex: meta.dataset[`evidence${side}AttemptIndex`] }
    }

    this.neighbours = {
      position: Number(meta.dataset.evidencePosition),
      total: Number(meta.dataset.evidenceTotal),
      probeName: meta.dataset.evidenceProbeName,
      previous: coordinate("Previous"),
      next: coordinate("Next")
    }
  }

  updateNav() {
    this.markActiveRow()

    if (!this.neighbours) {
      // A deep link to an attempt the active filter hides is real evidence with
      // nowhere to step; the drawer shows it and says nothing about position.
      if (this.hasPositionTarget) this.positionTarget.textContent = ""
      this.setStepEnabled(false, false)
      return
    }

    if (this.hasPositionTarget) {
      this.positionTarget.textContent = `${this.neighbours.position} of ${this.neighbours.total}`
    }
    if (this.hasTitleTarget) {
      this.titleTarget.textContent = this.neighbours.probeName || "Attempt"
    }
    this.setStepEnabled(Boolean(this.neighbours.previous), Boolean(this.neighbours.next))
  }

  setStepEnabled(previous, next) {
    if (this.hasPrevTarget) this.prevTarget.disabled = !previous
    if (this.hasNextTarget) this.nextTarget.disabled = !next
  }

  // The open attempt is often on another page now that stepping crosses them,
  // so there may be no row to mark -- the drawer stands on its own.
  markActiveRow() {
    if (!this.hasRowTarget) return

    this.rowTargets.forEach((row) => {
      const active =
        Boolean(this.current) &&
        row.dataset.probeResultId === String(this.current.probeResultId) &&
        row.dataset.attemptIndex === String(this.current.attemptIndex)

      row.classList.toggle("bg-zinc-800/60", active)
    })
  }

  handleKeydown(event) {
    if (this.drawerTarget.classList.contains("hidden")) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this.step(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.step(-1)
    }
  }

  // Copying evidence into a ticket or a chat is the common next step, so the
  // button confirms it worked. A refused clipboard (denied permission, an
  // insecure origin) rejects, and without a catch that surfaces only as an
  // unhandled rejection while the reader believes they copied something.
  copy(event) {
    const button = event.currentTarget
    const content = button.dataset.content
    if (content === undefined) return

    // An absent Clipboard API fails exactly as a refused one does. Returning
    // quietly here left the button looking like it had worked.
    const write = navigator.clipboard?.writeText(content)
    if (!write) {
      this.reportCopyFailure(button, new Error("Clipboard API unavailable"))
      return
    }

    write
      .then(() => this.confirmCopy(button))
      .catch((error) => this.reportCopyFailure(button, error))
  }

  reportCopyFailure(button, error) {
    console.error("[report-evidence] Clipboard write was refused:", error)
    button.setAttribute("aria-label", "Copy failed")
  }

  // Timer and original label are kept per button. Sharing one timer meant
  // copying the prompt then the response cancelled the prompt button's reset,
  // stranding its check icon; and re-copying within the window captured
  // "Copied" as the label to restore, so it never went back.
  confirmCopy(button) {
    const icon = button.querySelector("span")
    if (!icon) return

    this.copyResets ||= new Map()
    const pending = this.copyResets.get(button)
    const label = pending ? pending.label : button.getAttribute("aria-label")
    if (pending) clearTimeout(pending.timer)

    icon.classList.replace("icon-copy", "icon-check")
    button.setAttribute("aria-label", "Copied")

    const timer = setTimeout(() => {
      icon.classList.replace("icon-check", "icon-copy")
      button.setAttribute("aria-label", label)
      this.copyResets.delete(button)
    }, 1200)

    this.copyResets.set(button, { timer, label })
  }
}
