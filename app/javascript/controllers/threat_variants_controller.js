import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "container",
    "summary",
    "industryItem",
    "industryCheckbox",
    "subindustryCheckbox",
    "subindustryItem",
    "subindustriesContainer",
    "content",
    "disabledNotice"
  ]

  connect() {
    // Initialize industry checkbox states based on selected subindustries
    this.industryItemTargets.forEach(industryItem => {
      this.updateIndustryCheckboxState(industryItem)
    })

    this.updateSummary()
    // Start with all industries collapsed
    this.collapseAll()

    this._probeSelectionHandler = this.refreshEligibility.bind(this)
    this._listenerScope = this.element.closest('form') || document
    this._listenerScope.addEventListener('probe-category:probeSelectionChanged', this._probeSelectionHandler)

    this.refreshEligibility()
  }

  disconnect() {
    if (this._probeSelectionHandler && this._listenerScope) {
      this._listenerScope.removeEventListener('probe-category:probeSelectionChanged', this._probeSelectionHandler)
      this._probeSelectionHandler = null
      this._listenerScope = null
    }
  }

  refreshEligibility() {
    this.applyEligibility(this.computeEligibility())
  }

  computeEligibility() {
    const form = this.element.closest('form')
    if (!form) return false
    return form.querySelectorAll('[data-variant-eligible="true"]:checked').length > 0
  }

  applyEligibility(eligible) {
    const disabled = !eligible
    const variantCheckboxTargets = this.industryCheckboxTargets.concat(this.subindustryCheckboxTargets)

    variantCheckboxTargets.forEach(checkbox => {
      checkbox.disabled = disabled
    })

    if (this.hasContentTarget) {
      if (eligible) {
        this.contentTarget.classList.remove('opacity-50', 'pointer-events-none')
        this.contentTarget.removeAttribute('aria-disabled')
      } else {
        this.contentTarget.classList.add('opacity-50', 'pointer-events-none')
        this.contentTarget.setAttribute('aria-disabled', 'true')
      }
    }

    if (this.hasDisabledNoticeTarget) {
      if (eligible) {
        this.disabledNoticeTarget.classList.add('hidden')
      } else {
        this.disabledNoticeTarget.classList.remove('hidden')
      }
    }
  }

  clearSelections() {
    this.subindustryCheckboxTargets.forEach(cb => { cb.checked = false })
    this.industryItemTargets.forEach(industryItem => {
      this.updateIndustryCheckboxState(industryItem)
    })
    this.updateSummary()
  }

  // Toggle expand/collapse for an industry
  toggleIndustry(event) {
    event.stopPropagation()
    const industryItem = event.currentTarget.closest('.industry-item')
    const industryId = industryItem.dataset.industryId
    const subindustriesContainer = industryItem.querySelector('.subindustries-container')
    const chevron = industryItem.querySelector('.chevron-icon')

    if (subindustriesContainer) {
      const isHidden = subindustriesContainer.classList.contains('hidden')

      if (isHidden) {
        // Expand
        subindustriesContainer.classList.remove('hidden')
        if (chevron) chevron.classList.add('rotate-180')
      } else {
        // Collapse
        subindustriesContainer.classList.add('hidden')
        if (chevron) chevron.classList.remove('rotate-180')
      }
    }
  }

  // Select all subindustries for an industry
  selectAllIndustry(event) {
    const checkbox = event.target
    const industryId = checkbox.dataset.industryId
    const industryItem = checkbox.closest('.industry-item')

    // Find all subindustry checkboxes for this industry
    const subindustryCheckboxes = industryItem.querySelectorAll('.subindustry-checkbox')

    // Set all subindustries to match the industry checkbox state
    subindustryCheckboxes.forEach(subCheckbox => {
      subCheckbox.checked = checkbox.checked
    })

    this.updateSummary()
  }

  // Handle individual subindustry selection
  selectSubindustry(event) {
    const subindustryCheckbox = event.target
    const industryId = subindustryCheckbox.dataset.industryId
    const industryItem = subindustryCheckbox.closest('.industry-item')

    if (industryItem) {
      this.updateIndustryCheckboxState(industryItem)
    }

    this.updateSummary()
  }

  // Update industry checkbox based on subindustries
  updateIndustryCheckboxState(industryItem) {
    const industryCheckbox = industryItem.querySelector('.industry-checkbox')
    const subindustryCheckboxes = industryItem.querySelectorAll('.subindustry-checkbox')
    const checkedSubindustries = industryItem.querySelectorAll('.subindustry-checkbox:checked')

    if (!industryCheckbox) return

    if (checkedSubindustries.length === 0) {
      // None selected
      industryCheckbox.checked = false
      industryCheckbox.indeterminate = false
    } else if (checkedSubindustries.length === subindustryCheckboxes.length) {
      // All selected
      industryCheckbox.checked = true
      industryCheckbox.indeterminate = false
    } else {
      // Some selected (indeterminate state)
      industryCheckbox.checked = false
      industryCheckbox.indeterminate = true
    }
  }

  // Stop propagation to prevent triggering parent handlers
  stopPropagation(event) {
    event.stopPropagation()
  }

  // Expand all industries
  expandAll(event) {
    event.preventDefault()
    this.subindustriesContainerTargets.forEach(container => {
      container.classList.remove('hidden')
    })
    document.querySelectorAll('.chevron-icon').forEach(chevron => {
      chevron.classList.add('rotate-180')
    })
  }

  // Collapse all industries
  collapseAll(event) {
    if (event) event.preventDefault()
    this.subindustriesContainerTargets.forEach(container => {
      container.classList.add('hidden')
    })
    document.querySelectorAll('.chevron-icon').forEach(chevron => {
      chevron.classList.remove('rotate-180')
    })
  }

  // Update summary text
  updateSummary() {
    const selectedSubindustries = this.subindustryCheckboxTargets.filter(checkbox => checkbox.checked)
    const selectedIndustries = new Set()
    let totalCategories = selectedSubindustries.length

    selectedSubindustries.forEach(checkbox => {
      const subindustryItem = checkbox.closest('.subindustry-item')
      if (subindustryItem) {
        const industryName = subindustryItem.dataset.industryName
        if (industryName) {
          selectedIndustries.add(industryName)
        }
      }
    })

    // Update summary text
    if (this.hasSummaryTarget) {
      if (totalCategories === 0) {
        this.summaryTarget.textContent = 'No categories selected'
        this.summaryTarget.className = 'text-sm font-medium text-gray-700 dark:text-gray-300'
      } else {
        const industriesText = selectedIndustries.size === 1 ? 'industry' : 'industries'
        const categoriesText = totalCategories === 1 ? 'category' : 'categories'
        this.summaryTarget.textContent =
          `${totalCategories} ${categoriesText} selected from ${selectedIndustries.size} ${industriesText}`
        this.summaryTarget.className = 'text-sm font-medium text-blue-600 dark:text-blue-400'
      }
    }
  }
}