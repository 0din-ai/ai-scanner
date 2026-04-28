import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { storageKey: String }

  panelTargetConnected() {
    this.applyTab(this.resolveTab(this.storedTab()))
  }

  switch(event) {
    const selectedTab = event.currentTarget.dataset.tab
    this.storeTab(selectedTab)
    this.applyTab(selectedTab)
  }

  applyTab(selectedTab) {
    this.tabTargets.forEach((tab) => {
      if (tab.dataset.tab === selectedTab) {
        tab.classList.add("bg-zinc-800", "text-white")
        tab.classList.remove("text-zinc-400", "hover:text-zinc-200")
      } else {
        tab.classList.remove("bg-zinc-800", "text-white")
        tab.classList.add("text-zinc-400", "hover:text-zinc-200")
      }
    })

    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.tab !== selectedTab)
    })
  }

  resolveTab(candidate) {
    const known = this.tabTargets.map((tab) => tab.dataset.tab)
    if (candidate && known.includes(candidate)) return candidate
    return "timeline"
  }

  storedTab() {
    if (!this.hasStorageKeyValue) return null

    try {
      return sessionStorage.getItem(this.storageKeyValue)
    } catch (err) {
      return null
    }
  }

  storeTab(selectedTab) {
    if (!this.hasStorageKeyValue) return

    try {
      sessionStorage.setItem(this.storageKeyValue, selectedTab)
    } catch (err) {
      // best-effort persistence; ignore failures (private mode, embedded contexts, full quota).
    }
  }
}
