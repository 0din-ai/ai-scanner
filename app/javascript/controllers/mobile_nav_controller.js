import { Controller } from "@hotwired/stimulus"

/**
 * Mobile Navigation Controller
 *
 * Handles the mobile navigation drawer toggle functionality.
 * Replaces Flowbite's data-drawer-* attributes with explicit Stimulus control.
 *
 * Usage:
 *   <body data-controller="mobile-nav">
 *     <button data-action="click->mobile-nav#toggle">Menu</button>
 *     <div data-mobile-nav-target="backdrop" class="hidden"></div>
 *     <div data-mobile-nav-target="drawer" class="-translate-x-full">...</div>
 *   </body>
 */
export default class extends Controller {
  static targets = ["drawer", "backdrop", "toggleButton"]
  static values = { open: Boolean }

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleResize = this.handleResize.bind(this)

    document.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("resize", this.handleResize)
    this.syncAriaExpanded()
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("resize", this.handleResize)
    this.enableBodyScroll()
  }

  toggle() {
    this.openValue ? this.close() : this.open()
  }

  open() {
    this.openValue = true
    this.syncAriaExpanded()

    // Show drawer
    this.drawerTarget.classList.remove("-translate-x-full")
    this.drawerTarget.classList.add("translate-x-0")

    // Show backdrop
    this.backdropTarget.classList.remove("hidden")
    this.backdropTarget.classList.add("opacity-100")

    // Prevent body scroll
    this.disableBodyScroll()

    // Focus trap - focus first focusable element in drawer
    const firstFocusable = this.drawerTarget.querySelector(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    )
    if (firstFocusable) {
      firstFocusable.focus()
    }
  }

  close() {
    this.openValue = false
    this.syncAriaExpanded()

    // Hide drawer
    this.drawerTarget.classList.add("-translate-x-full")
    this.drawerTarget.classList.remove("translate-x-0")

    // Hide backdrop
    this.backdropTarget.classList.add("hidden")
    this.backdropTarget.classList.remove("opacity-100")

    // Re-enable body scroll
    this.enableBodyScroll()
  }

  syncAriaExpanded() {
    this.toggleButtonTargets.forEach(button => {
      button.setAttribute("aria-expanded", String(this.openValue))
    })
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.openValue) {
      this.close()
    }
  }

  handleResize() {
    // Close drawer if window is resized to xl+ breakpoint (1280px)
    if (window.innerWidth >= 1280 && this.openValue) {
      this.close()
    }
  }

  toggleSubmenu(event) {
    // Toggle the data-open attribute on the parent li element
    const button = event.currentTarget
    const parentLi = button.closest("li")
    if (parentLi) {
      if (parentLi.hasAttribute("data-open")) {
        parentLi.removeAttribute("data-open")
      } else {
        parentLi.setAttribute("data-open", "")
      }
    }
  }

  disableBodyScroll() {
    document.body.style.overflow = "hidden"
  }

  enableBodyScroll() {
    document.body.style.overflow = ""
  }
}
