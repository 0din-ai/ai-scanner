import { Controller } from "@hotwired/stimulus"

// Cancelable debounce utility to prevent rapid-fire updates
// Returns a function with a .cancel() method for cleanup on disconnect
function debounce(func, wait) {
  let timeout
  const debouncedFn = function(...args) {
    clearTimeout(timeout)
    timeout = setTimeout(() => func.apply(this, args), wait)
  }
  debouncedFn.cancel = () => clearTimeout(timeout)
  return debouncedFn
}

export default class extends Controller {
  static targets = ["category", "categoryCheckbox", "probeCheckbox", "content", "chevron", "selectionCount", "selectAllCheckbox", "searchInput", "totalCounter", "autoUpdateContainer", "tooltip", "tokenCounter", "monthlyTokenContainer", "monthlyTokenCounter"]

  connect() {
    this.runsPerMonth = 0
    this.updateAllCategoryStates()
    this.updateSelectAllState()
    this.updateAllAutoUpdateVisibility()
    this.updateTokenCounter()

    // Create debounced version of updateTokenCounter for batch selections
    this.debouncedUpdateTokenCounter = debounce(this.updateTokenCounter.bind(this), 50)

    // Listen for schedule changes from scan-recurrence controller
    // Store bound handler for proper cleanup
    this._scheduleChangedHandler = this.handleScheduleChanged.bind(this)
    this.element.addEventListener('scheduleChanged', this._scheduleChangedHandler)
  }

  disconnect() {
    // Cancel any pending debounced token counter update
    this.debouncedUpdateTokenCounter?.cancel()

    // Clean up event listeners to prevent memory leaks
    if (this._scheduleChangedHandler) {
      this.element.removeEventListener('scheduleChanged', this._scheduleChangedHandler)
      this._scheduleChangedHandler = null
    }

    this.contentTargets.forEach(content => {
      content.style.maxHeight = null
    })

    this.categoryTargets.forEach(category => {
      const header = category.querySelector('[aria-expanded]')
      if (header) {
        header.removeAttribute('aria-expanded')
      }
    })

    // Stimulus automatically cleans up targets, no need to set them to []
    this._categoryStates = null
  }

  toggleCategory(event) {
    if (event.target.type === 'checkbox') {
      return
    }

    const categoryId = event.currentTarget.dataset.probeCategoryId
    const content = this.contentTargets.find(el => el.dataset.categoryId === categoryId)
    const chevron = this.chevronTargets.find(el => el.dataset.categoryId === categoryId)
    const header = event.currentTarget

    if (!content) return

    const isExpanded = header.getAttribute("aria-expanded") === "true"

    if (isExpanded) {
      content.style.maxHeight = "0px"
      chevron.classList.remove("rotate-180")
      header.setAttribute("aria-expanded", "false")
    } else {
      content.style.maxHeight = content.scrollHeight + "px"
      chevron.classList.add("rotate-180")
      header.setAttribute("aria-expanded", "true")
    }
  }

  handleCheckboxClick(event) {
    event.stopPropagation()
  }

  selectCategory(event) {
    const checkbox = event.target
    const categoryId = checkbox.dataset.categoryId
    const isChecked = checkbox.checked
    const categoryProbes = this.probeCheckboxTargets.filter(
      probe => probe.dataset.categoryId === categoryId
    )

    categoryProbes.forEach(probe => {
      probe.checked = isChecked
    })

    this.updateCategoryState({ currentTarget: { dataset: { categoryId } } })
    this.updateSelectAllState()
    this.updateCommunityParentState()
    this.debouncedUpdateTokenCounter()
  }

  // Handle the community parent checkbox selecting all nested community categories
  selectCommunityParent(event) {
    const isChecked = event.target.checked

    // Find all nested community category checkboxes (inside the community parent)
    const communityParent = event.target.closest('[data-community-parent="true"]')
    if (!communityParent) return

    const nestedCategories = communityParent.querySelectorAll('[data-nested="true"]')
    nestedCategories.forEach(category => {
      const categoryCheckbox = category.querySelector('[data-probe-category-target="categoryCheckbox"]')
      if (categoryCheckbox) {
        const categoryId = categoryCheckbox.dataset.categoryId
        categoryCheckbox.checked = isChecked
        categoryCheckbox.indeterminate = false

        // Select/deselect all probes in this category
        const categoryProbes = this.probeCheckboxTargets.filter(
          probe => probe.dataset.categoryId === categoryId
        )
        categoryProbes.forEach(probe => {
          probe.checked = isChecked
        })

        this.updateSingleCategoryState(categoryId)
      }
    })

    this.updateCommunityParentState()
    this.updateSelectAllState()
    this.debouncedUpdateTokenCounter()
  }

  // Update the community parent checkbox state based on nested categories
  updateCommunityParentState() {
    const communityParentCheckbox = this.categoryCheckboxTargets.find(
      cb => cb.dataset.isParent === "true" && cb.dataset.categoryId === "community_probes"
    )
    if (!communityParentCheckbox) return

    const communityParent = communityParentCheckbox.closest('[data-community-parent="true"]')
    if (!communityParent) return

    // Get all probes in nested community categories
    const nestedCategories = communityParent.querySelectorAll('[data-nested="true"]')
    let totalProbes = 0
    let checkedProbes = 0

    nestedCategories.forEach(category => {
      const categoryCheckbox = category.querySelector('[data-probe-category-target="categoryCheckbox"]')
      if (categoryCheckbox) {
        const categoryId = categoryCheckbox.dataset.categoryId
        const categoryProbes = this.probeCheckboxTargets.filter(
          probe => probe.dataset.categoryId === categoryId
        )
        totalProbes += categoryProbes.length
        checkedProbes += categoryProbes.filter(p => p.checked).length
      }
    })

    // Update parent checkbox state
    if (checkedProbes === 0) {
      communityParentCheckbox.checked = false
      communityParentCheckbox.indeterminate = false
    } else if (checkedProbes === totalProbes) {
      communityParentCheckbox.checked = true
      communityParentCheckbox.indeterminate = false
    } else {
      communityParentCheckbox.checked = false
      communityParentCheckbox.indeterminate = true
    }

    // Update selection count badge for community parent
    const selectionCount = this.selectionCountTargets.find(
      el => el.dataset.categoryId === "community_probes"
    )
    if (selectionCount) {
      selectionCount.textContent = `${checkedProbes} of ${totalProbes} selected`

      if (checkedProbes === 0) {
        selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-zinc-700/50 text-contentTertiary border border-borderPrimary"
      } else if (checkedProbes === totalProbes) {
        selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-green-500/20 text-green-400 border border-green-500/30"
      } else {
        selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-primary/20 text-primary border border-primary/30"
      }
    }
  }

  selectAllProbes(event) {
    const isChecked = event.target.checked

    this.probeCheckboxTargets.forEach(probe => {
      probe.checked = isChecked
    })

    this.categoryCheckboxTargets.forEach(categoryCheckbox => {
      categoryCheckbox.checked = isChecked
      categoryCheckbox.indeterminate = false
    })

    this.updateAllCategoryStates()
    this.debouncedUpdateTokenCounter()
  }

  updateCategoryState(event) {
    const categoryId = event.currentTarget.dataset.categoryId
    this.updateSingleCategoryState(categoryId)
    this.updateSelectAllState()
    this.debouncedUpdateTokenCounter()
  }

  updateSingleCategoryState(categoryId) {
    const categoryCheckbox = this.categoryCheckboxTargets.find(
      cb => cb.dataset.categoryId === categoryId
    )
    const categoryProbes = this.probeCheckboxTargets.filter(
      probe => probe.dataset.categoryId === categoryId
    )
    const selectionCount = this.selectionCountTargets.find(
      el => el.dataset.categoryId === categoryId
    )

    if (!categoryCheckbox || !selectionCount) return

    const checkedCount = categoryProbes.filter(probe => probe.checked).length
    const totalCount = categoryProbes.length

    if (checkedCount === 0) {
      categoryCheckbox.checked = false
      categoryCheckbox.indeterminate = false
    } else if (checkedCount === totalCount) {
      categoryCheckbox.checked = true
      categoryCheckbox.indeterminate = false
    } else {
      categoryCheckbox.checked = false
      categoryCheckbox.indeterminate = true
    }

    selectionCount.textContent = `${checkedCount} of ${totalCount} selected`

    if (checkedCount === 0) {
      selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-zinc-700/50 text-contentTertiary border border-borderPrimary"
    } else if (checkedCount === totalCount) {
      selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-green-500/20 text-green-400 border border-green-500/30"
    } else {
      selectionCount.className = "inline-flex items-center px-2.5 py-0.5 rounded text-xs font-medium bg-primary/20 text-primary border border-primary/30"
    }

    this.updateAutoUpdateVisibility(categoryId, checkedCount, totalCount)
  }

  updateAutoUpdateVisibility(categoryId, checkedCount = null, totalCount = null) {
    const autoUpdateContainer = this.autoUpdateContainerTargets.find(
      el => el.dataset.categoryId === categoryId
    )

    if (!autoUpdateContainer) return

    if (checkedCount === null || totalCount === null) {
      const categoryProbes = this.probeCheckboxTargets.filter(
        probe => probe.dataset.categoryId === categoryId
      )
      checkedCount = categoryProbes.filter(probe => probe.checked).length
      totalCount = categoryProbes.length
    }

    if (checkedCount === totalCount && totalCount > 0) {
      autoUpdateContainer.classList.remove('hidden')
      autoUpdateContainer.classList.add('flex')
    } else {
      autoUpdateContainer.classList.add('hidden')
      autoUpdateContainer.classList.remove('flex')
    }
  }

  updateAllAutoUpdateVisibility() {
    const categoryIds = [...new Set(this.probeCheckboxTargets.map(p => p.dataset.categoryId))]
    categoryIds.forEach(categoryId => this.updateAutoUpdateVisibility(categoryId))
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  updateAllCategoryStates() {
    const categoryIds = [...new Set(this.probeCheckboxTargets.map(p => p.dataset.categoryId))]
    categoryIds.forEach(categoryId => this.updateSingleCategoryState(categoryId))
    this.updateCommunityParentState()
  }

  updateSelectAllState() {
    const totalProbes = this.probeCheckboxTargets.length
    const checkedProbes = this.probeCheckboxTargets.filter(p => p.checked).length

    // Update selectAll checkbox if it exists
    if (this.hasSelectAllCheckboxTarget) {
      if (checkedProbes === 0) {
        this.selectAllCheckboxTarget.checked = false
        this.selectAllCheckboxTarget.indeterminate = false
      } else if (checkedProbes === totalProbes) {
        this.selectAllCheckboxTarget.checked = true
        this.selectAllCheckboxTarget.indeterminate = false
      } else {
        this.selectAllCheckboxTarget.checked = false
        this.selectAllCheckboxTarget.indeterminate = true
      }
    }

    // Always update total counter if it exists
    if (this.hasTotalCounterTarget) {
      this.totalCounterTarget.textContent = `${checkedProbes} of ${totalProbes} selected`

      if (checkedProbes === 0) {
        this.totalCounterTarget.className = "px-3 py-1 bg-zinc-700/50 text-contentTertiary rounded text-sm font-medium border border-borderPrimary"
      } else if (checkedProbes === totalProbes) {
        this.totalCounterTarget.className = "px-3 py-1 bg-green-500/20 text-green-400 rounded text-sm font-medium border border-green-500/30"
      } else {
        this.totalCounterTarget.className = "px-3 py-1 bg-primary/20 text-primary rounded text-sm font-medium border border-primary/30"
      }
    }
  }

  expandAll(event) {
    event.preventDefault()

    this.categoryTargets.forEach(category => {
      const categoryId = category.querySelector('[data-probe-category-id]')?.dataset.probeCategoryId
      if (!categoryId) return

      const content = this.contentTargets.find(el => el.dataset.categoryId === categoryId)
      const chevron = this.chevronTargets.find(el => el.dataset.categoryId === categoryId)
      const header = category.querySelector('[aria-expanded]')

      if (content && header) {
        content.style.maxHeight = content.scrollHeight + "px"
        chevron?.classList.add("rotate-180")
        header.setAttribute("aria-expanded", "true")
      }
    })
  }

  collapseAll(event) {
    event.preventDefault()

    this.categoryTargets.forEach(category => {
      const categoryId = category.querySelector('[data-probe-category-id]')?.dataset.probeCategoryId
      if (!categoryId) return

      const content = this.contentTargets.find(el => el.dataset.categoryId === categoryId)
      const chevron = this.chevronTargets.find(el => el.dataset.categoryId === categoryId)
      const header = category.querySelector('[aria-expanded]')

      if (content && header) {
        content.style.maxHeight = "0px"
        chevron?.classList.remove("rotate-180")
        header.setAttribute("aria-expanded", "false")
      }
    })
  }


  filterProbes(event) {
    const searchTerm = event.target.value.toLowerCase()

    this.probeCheckboxTargets.forEach(probe => {
      const label = probe.nextElementSibling?.textContent?.toLowerCase() || ''
      const probeContainer = probe.closest('div')

      if (searchTerm === '' || label.includes(searchTerm)) {
        probeContainer.style.display = ''
      } else {
        probeContainer.style.display = 'none'
      }
    })

    if (searchTerm !== '') {
      this.categoryTargets.forEach(category => {
        const categoryId = category.querySelector('[data-probe-category-id]')?.dataset.probeCategoryId
        if (categoryId) {
          const content = this.contentTargets.find(el => el.dataset.categoryId === categoryId)
          const chevron = this.chevronTargets.find(el => el.dataset.categoryId === categoryId)
          const header = category.querySelector('[aria-expanded]')

          if (content && header) {
            content.style.maxHeight = content.scrollHeight + "px"
            chevron?.classList.add("rotate-180")
            header.setAttribute("aria-expanded", "true")
          }
        }
      })
    } else {
      this.categoryTargets.forEach(category => {
        const categoryId = category.querySelector('[data-probe-category-id]')?.dataset.probeCategoryId
        if (categoryId) {
          const content = this.contentTargets.find(el => el.dataset.categoryId === categoryId)
          const chevron = this.chevronTargets.find(el => el.dataset.categoryId === categoryId)
          const header = category.querySelector('[aria-expanded]')

          if (content && header) {
            content.style.maxHeight = "0px"
            chevron?.classList.remove("rotate-180")
            header.setAttribute("aria-expanded", "false")
          }
        }
      })
    }
  }

  showTooltip(event) {
    const tooltip = event.currentTarget.querySelector('[data-probe-category-target="tooltip"]')
    if (!tooltip) return

    const icon = event.currentTarget.querySelector('span')
    const rect = icon.getBoundingClientRect()

    tooltip.classList.remove('hidden')
    const tooltipHeight = tooltip.offsetHeight
    const tooltipWidth = tooltip.offsetWidth

    let left = rect.left + rect.width / 2 - tooltipWidth / 2
    const top = rect.top - tooltipHeight - 8

    const padding = 8
    if (left < padding) {
      left = padding
    } else if (left + tooltipWidth > window.innerWidth - padding) {
      left = window.innerWidth - tooltipWidth - padding
    }

    tooltip.style.left = left + 'px'
    tooltip.style.top = top + 'px'
  }

  hideTooltip(event) {
    const tooltip = event.currentTarget.querySelector('[data-probe-category-target="tooltip"]')
    if (tooltip) {
      tooltip.classList.add('hidden')
      tooltip.style.left = ''
      tooltip.style.top = ''
    }
  }

  // Token counting methods
  updateTokenCounter() {
    if (!this.hasTokenCounterTarget) return

    const totalTokens = this.calculateTotalTokens()
    this._cachedTotalTokens = totalTokens
    this.tokenCounterTarget.textContent = this.formatNumber(totalTokens)

    this.updateMonthlyProjection(totalTokens)

    // Dispatch event to parent scan-form controller with totalTokens in detail
    // Using bubbling event on element instead of document for better encapsulation
    this.dispatch('probeSelectionChanged', {
      detail: { totalTokens },
      bubbles: true
    })
  }

  calculateTotalTokens() {
    return this.probeCheckboxTargets
      .filter(probe => probe.checked)
      .reduce((sum, probe) => {
        const tokens = parseInt(probe.dataset.inputTokens, 10) || 0
        return sum + tokens
      }, 0)
  }

  // Expose totalTokens as a getter for outlet access from scan-form controller
  get totalTokens() {
    // Return cached value if available, otherwise calculate
    return this._cachedTotalTokens ?? this.calculateTotalTokens()
  }

  formatNumber(num) {
    // Use en-US locale for consistent formatting across browsers
    return num.toLocaleString('en-US')
  }

  handleScheduleChanged(event) {
    this.runsPerMonth = event.detail?.runsPerMonth || 0
    this.updateMonthlyProjection(this.calculateTotalTokens())
  }

  updateMonthlyProjection(totalTokens) {
    if (!this.hasMonthlyTokenContainerTarget || !this.hasMonthlyTokenCounterTarget) return

    if (this.runsPerMonth > 0) {
      const monthlyTokens = totalTokens * this.runsPerMonth
      this.monthlyTokenCounterTarget.textContent = this.formatNumber(monthlyTokens)
      this.monthlyTokenContainerTarget.classList.remove('hidden')
      this.monthlyTokenContainerTarget.classList.add('flex')
    } else {
      this.monthlyTokenContainerTarget.classList.add('hidden')
      this.monthlyTokenContainerTarget.classList.remove('flex')
    }
  }

}
