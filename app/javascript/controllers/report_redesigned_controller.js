import { Controller } from "@hotwired/stimulus"
import { colors, isDark } from "graphs/common"
import { disposeCharts, resizeCharts } from "utils"
import { BRAND_FONT } from "config/chartConfig"

export default class extends Controller {
  static targets = [
    "probeCard", "asrHistoryChart", "topProbesChart",
    "detectorChevron", "detectorContent",
    "variantChevron", "variantContent",
    "variantPromptsChevron", "variantPromptsContent",
    "attemptsChevron", "attemptsContent",
    "probesChevron", "probesContent",
    "sortLabel", "sortButton",
    "attemptChevron", "attemptContent",
    "tabOverview", "tabProbes",
    "tabContentOverview", "tabContentProbes",
    "probesFrame",
    "logsChevron", "logsContent"
  ]

  static values = {
    sortBy: { type: String, default: "asr" },
    probesTabUrl: String
  }

  async connect() {
    this._attemptsErrorListeners = []
    this.setupProbeCardToggle()

    if (this.hasAsrHistoryChartTarget || this.hasTopProbesChartTarget) {
      await import("/js/echarts.js")
      this.charts = {}
      this.initStatisticsCharts()

      this.resizeHandler = () => resizeCharts(this.charts)
      window.addEventListener('resize', this.resizeHandler)
    }
  }

  disconnect() {
    if (this.charts) {
      disposeCharts(this.charts)
    }

    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler)
      this.resizeHandler = null
    }

    if (this._attemptsErrorListeners) {
      for (const { target, event, handler } of this._attemptsErrorListeners) {
        target.removeEventListener(event, handler)
      }
      this._attemptsErrorListeners = []
    }
  }

  switchTab(event) {
    const tab = event.currentTarget.dataset.tab

    if (tab === 'overview') {
      this.tabOverviewTarget.classList.add('text-primary')
      this.tabOverviewTarget.classList.remove('text-contentTertiary', 'hover:text-contentSecondary')
      this.tabProbesTarget.classList.remove('text-primary')
      this.tabProbesTarget.classList.add('text-contentTertiary', 'hover:text-contentSecondary')
      this.tabContentOverviewTarget.classList.remove('hidden')
      this.tabContentProbesTarget.classList.add('hidden')

      // Resize charts when switching back to overview tab
      if (this.charts) {
        setTimeout(() => resizeCharts(this.charts), 50)
      }
    } else if (tab === 'probes') {
      this.tabProbesTarget.classList.add('text-primary')
      this.tabProbesTarget.classList.remove('text-contentTertiary', 'hover:text-contentSecondary')
      this.tabOverviewTarget.classList.remove('text-primary')
      this.tabOverviewTarget.classList.add('text-contentTertiary', 'hover:text-contentSecondary')
      this.tabContentProbesTarget.classList.remove('hidden')
      this.tabContentOverviewTarget.classList.add('hidden')

      // Lazy-load probes turbo frame on first tab switch
      if (this.hasProbesFrameTarget && !this.probesFrameTarget.src) {
        const probesUrl = this.probesTabUrlValue
        const onProbesError = (e) => {
          e.preventDefault()
          console.error(`[report-redesigned] Failed to load probes tab from ${probesUrl}:`, e)
          this.probesFrameTarget.innerHTML = '<p class="text-sm text-red-400 p-4 font-sans">Failed to load probes. Please refresh the page.</p>'
        }
        this.probesFrameTarget.addEventListener("turbo:frame-missing", onProbesError, { once: true })
        this.probesFrameTarget.addEventListener("turbo:fetch-request-error", onProbesError, { once: true })
        this.probesFrameTarget.src = probesUrl
      }
    }
  }

  initStatisticsCharts() {
    if (this.hasAsrHistoryChartTarget) {
      this.initAsrHistoryChart()
    }
    if (this.hasTopProbesChartTarget) {
      this.initTopProbesChart()
    }
  }

  async initAsrHistoryChart() {
    const chartElement = this.asrHistoryChartTarget
    const reportId = chartElement.dataset.reportId

    try {
    const response = await fetch(`/reports/${reportId}/asr_history.json`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()

    const chart = echarts.init(chartElement)
    const option = {
      backgroundColor: '#000000',
      textStyle: {
        color: '#FFFFFF',
        fontFamily: BRAND_FONT
      },
      tooltip: {
        trigger: 'axis',
        backgroundColor: 'rgba(39, 39, 42, 0.6)',
        borderWidth: 0,
        borderRadius: 12,
        padding: [8, 12],
        textStyle: {
          color: '#FFFFFF',
          fontFamily: BRAND_FONT,
          fontSize: 12
        },
        extraCssText: '-webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px);'
      },
      legend: {
        data: ['ASR', 'Successful Attacks'],
        textStyle: {
          color: 'rgba(255, 255, 255, 0.87)',
          fontSize: 9,
          fontWeight: 300,
          fontFamily: BRAND_FONT
        },
        icon: 'rect',
        itemWidth: 15,
        itemHeight: 2,
        itemGap: 15,
        top: 0
      },
      grid: {
        left: '3%',
        right: '3%',
        bottom: '3%',
        top: '15%',
        containLabel: true
      },
      xAxis: {
        type: 'category',
        boundaryGap: false,
        data: data.dates || [],
        axisLine: {
          lineStyle: { color: 'rgba(255, 255, 255, 0.1)' }
        },
        axisLabel: {
          color: '#FFFFFF',
          fontFamily: BRAND_FONT,
          fontSize: 10,
          rotate: 45
        }
      },
      yAxis: [
        {
          type: 'value',
          position: 'left',
          axisLine: {
            show: false
          },
          axisLabel: {
            color: '#FFFFFF',
            fontFamily: BRAND_FONT,
            fontSize: 10,
            formatter: '{value}%'
          },
          splitLine: {
            lineStyle: {
              color: 'rgba(255, 255, 255, 0.1)'
            }
          },
          min: 0,
          max: 100
        },
        {
          type: 'value',
          position: 'right',
          axisLine: {
            show: false
          },
          axisLabel: {
            color: '#AE49EC',
            fontFamily: BRAND_FONT,
            fontSize: 10
          },
          splitLine: {
            show: false
          }
        }
      ],
      series: [
        {
          name: 'ASR',
          type: 'line',
          yAxisIndex: 0,
          data: data.asr_values || [],
          smooth: false,
          symbol: 'none',
          showSymbol: false,
          lineStyle: {
            color: '#F89D53',
            width: 2
          },
          itemStyle: {
            color: '#F89D53'
          }
        },
        {
          name: 'Successful Attacks',
          type: 'line',
          yAxisIndex: 1,
          data: data.successful_attacks || [],
          smooth: false,
          symbol: 'none',
          showSymbol: false,
          lineStyle: {
            color: '#AE49EC',
            width: 2
          },
          itemStyle: {
            color: '#AE49EC'
          }
        }
      ]
    }

    chart.setOption(option)
    this.charts['asrHistory'] = chart
    } catch (err) {
      console.error(`[report-redesigned] Failed to load ASR history chart for report ${reportId}:`, err)
      chartElement.innerHTML = '<p class="text-sm text-red-400 p-4 font-sans">Failed to load chart data.</p>'
    }
  }

  async initTopProbesChart() {
    const chartElement = this.topProbesChartTarget
    const reportId = chartElement.dataset.reportId

    try {
    const response = await fetch(`/reports/${reportId}/top_probes.json`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()

    const chart = echarts.init(chartElement)

    const modelNames = data.probe_names || []
    const asrValues = data.asr_values || []

    const option = {
      backgroundColor: '#000000',
      textStyle: {
        color: '#FFFFFF',
        fontFamily: BRAND_FONT
      },
      tooltip: {
        trigger: 'axis',
        axisPointer: {
          type: 'shadow'
        },
        backgroundColor: 'rgba(39, 39, 42, 0.6)',
        borderWidth: 0,
        borderRadius: 12,
        padding: [8, 12],
        textStyle: {
          color: '#FFFFFF',
          fontFamily: BRAND_FONT,
          fontSize: 12
        },
        extraCssText: '-webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px);',
        formatter: function(params) {
          const item = params[0]
          return `${item.name}: ${item.value}%`
        }
      },
      legend: {
        show: false
      },
      grid: {
        left: '1%',
        right: '4%',
        bottom: '3%',
        top: 0,
        containLabel: true
      },
      xAxis: {
        type: 'value',
        axisLine: {
          lineStyle: { color: 'rgba(255, 255, 255, 0.1)' }
        },
        axisLabel: {
          color: '#FFFFFF',
          fontFamily: BRAND_FONT,
          fontSize: 10
        },
        splitLine: {
          lineStyle: {
            color: 'rgba(255, 255, 255, 0.1)',
            type: 'dashed'
          }
        },
        max: 100
      },
      yAxis: {
        type: 'category',
        data: modelNames.map(name => name.length > 20 ? name.substring(0, 20) + '...' : name),
        axisLine: {
          lineStyle: { color: 'rgba(255, 255, 255, 0.1)' }
        },
        axisLabel: {
          color: '#FFFFFF',
          fontFamily: BRAND_FONT,
          fontSize: 10
        }
      },
      series: [
        {
          name: 'ASR',
          type: 'bar',
          data: asrValues,
          barWidth: 16,
          itemStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
              { offset: 0, color: '#B94E10' },
              { offset: 1, color: '#FF9456' }
            ])
          },
          emphasis: {
            itemStyle: {
              color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
                { offset: 0, color: '#C85D1A' },
                { offset: 1, color: '#FDB97F' }
              ])
            }
          },
          barCategoryGap: '20%'
        }
      ]
    }

    chart.setOption(option)
    this.charts['topProbes'] = chart
    } catch (err) {
      console.error(`[report-redesigned] Failed to load top probes chart for report ${reportId}:`, err)
      chartElement.innerHTML = '<p class="text-sm text-red-400 p-4 font-sans">Failed to load chart data.</p>'
    }
  }

  toggleDetectorStats(event) {
    const button = event.currentTarget
    const content = this.detectorContentTarget
    const chevron = this.detectorChevronTarget

    if (!content || !chevron) return

    const isHidden = content.classList.contains("hidden")

    if (isHidden) {
      content.classList.remove("hidden")
      chevron.style.transform = "rotate(180deg)"
    } else {
      content.classList.add("hidden")
      chevron.style.transform = "rotate(0deg)"
    }
  }

  toggleMetadata(event) {
    const button = event.currentTarget
    const content = button.parentElement.querySelector("[data-target='metadata-content']")
    const chevron = button.querySelector("[data-target='metadata-chevron']")

    if (!content || !chevron) return

    const isHidden = content.classList.contains("hidden")

    if (isHidden) {
      content.classList.remove("hidden")
      chevron.style.transform = "rotate(180deg)"
    } else {
      content.classList.add("hidden")
      chevron.style.transform = "rotate(0deg)"
    }
  }

  toggleLogs(event) {
    const content = this.logsContentTarget
    const chevron = this.logsChevronTarget

    if (!content || !chevron) return

    const isHidden = content.classList.contains("hidden")

    if (isHidden) {
      content.classList.remove("hidden")
      chevron.classList.add("rotate-180")
    } else {
      content.classList.add("hidden")
      chevron.classList.remove("rotate-180")
    }
  }

  setupProbeCardToggle() {
    this.element.addEventListener("click", (e) => {
      const probeCard = e.target.closest("[data-action*='toggleProbeDetails']")
      if (!probeCard) return

      this.toggleProbeCard(probeCard)
    })
  }

  toggleProbeDetails(event) {
    this.toggleProbeCard(event.currentTarget)
  }

  toggleProbeCard(card) {
    const detailsSection = card.querySelector("[data-target='probe-card-details']")
    const chevron = card.querySelector("[data-target='probe-card-chevron']")

    if (!detailsSection || !chevron) return

    const isHidden = detailsSection.classList.contains("hidden")

    if (isHidden) {
      detailsSection.classList.remove("hidden")
      chevron.style.transform = "rotate(180deg)"
    } else {
      detailsSection.classList.add("hidden")
      chevron.style.transform = "rotate(0deg)"
    }
  }

  expandAll() {
    const cards = this.element.querySelectorAll("[data-action*='toggleProbeDetails']")
    cards.forEach((card) => {
      const detailsSection = card.querySelector("[data-target='probe-card-details']")
      const chevron = card.querySelector("[data-target='probe-card-chevron']")

      if (detailsSection && !detailsSection.classList.contains("hidden")) {
        return
      }

      if (detailsSection && chevron) {
        detailsSection.classList.remove("hidden")
        chevron.style.transform = "rotate(180deg)"
      }
    })
  }

  collapseAll() {
    const cards = this.element.querySelectorAll("[data-action*='toggleProbeDetails']")
    cards.forEach((card) => {
      const detailsSection = card.querySelector("[data-target='probe-card-details']")
      const chevron = card.querySelector("[data-target='probe-card-chevron']")

      if (detailsSection && detailsSection.classList.contains("hidden")) {
        return
      }

      if (detailsSection && chevron) {
        detailsSection.classList.add("hidden")
        chevron.style.transform = "rotate(0deg)"
      }
    })
  }

  scrollToProbe(event) {
    const probeId = event.target.dataset.probeId
    if (!probeId) return

    const probeElement = document.querySelector(`[data-probe-id="${probeId}"]`)
    if (!probeElement) return

    probeElement.scrollIntoView({ behavior: "smooth", block: "start" })
    probeElement.classList.add("ring-2", "ring-orange-500", "ring-offset-2")

    setTimeout(() => {
      probeElement.classList.remove("ring-2", "ring-orange-500", "ring-offset-2")
    }, 2000)
  }

  filterProbes(event) {
    const searchTerm = event.target.value.toLowerCase()
    const cards = this.element.querySelectorAll("[data-action*='toggleProbeDetails']")

    cards.forEach((card) => {
      const probeName = card.querySelector("h3")?.textContent.toLowerCase() || ""
      const isMatch = probeName.includes(searchTerm) || searchTerm === ""

      card.style.display = isMatch ? "" : "none"
    })
  }

  toggleProbeVariants(event) {
    const button = event.currentTarget
    const probeIndex = button.dataset.probeIndex || '0'
    const variantContent = document.querySelector(`[data-report-redesigned-target="variantContent"][data-probe-index="${probeIndex}"]`)
    const variantChevron = document.querySelector(`[data-report-redesigned-target="variantChevron"][data-probe-index="${probeIndex}"]`)

    if (!variantContent || !variantChevron) return

    const isHidden = variantContent.classList.contains("hidden")

    if (isHidden) {
      variantContent.classList.remove("hidden")
      variantChevron.style.transform = "rotate(180deg)"
    } else {
      variantContent.classList.add("hidden")
      variantChevron.style.transform = "rotate(0deg)"
    }
  }

  toggleProbeAttempts(event) {
    event.stopPropagation()

    const button = event.currentTarget
    const probeResultId = button.dataset.probeResultId
    const attemptsContent = this.element.querySelector(`[data-report-redesigned-target="attemptsContent"][data-probe-result-id="${probeResultId}"]`)
    const attemptsChevron = this.element.querySelector(`[data-report-redesigned-target="attemptsChevron"][data-probe-result-id="${probeResultId}"]`)

    if (!attemptsContent || !attemptsChevron) return

    const isHidden = attemptsContent.classList.contains("hidden")

    if (isHidden) {
      attemptsContent.classList.remove("hidden")
      attemptsChevron.style.transform = "rotate(180deg)"

      const turboFrame = attemptsContent.querySelector("turbo-frame")
      if (turboFrame && !turboFrame.src) {
        const attemptsUrl = turboFrame.dataset.probeAttemptsUrl
        const onAttemptsError = (e) => {
          e.preventDefault()
          console.error(`[report-redesigned] Failed to load probe attempts from ${attemptsUrl}:`, e)
          turboFrame.removeAttribute("src")
          turboFrame.innerHTML = '<p class="text-sm text-red-400 p-4 font-sans">Failed to load attempts. Please try again.</p>'
        }
        const trackedHandler = (e) => {
          onAttemptsError(e)
          if (this._attemptsErrorListeners) {
            this._attemptsErrorListeners = this._attemptsErrorListeners.filter(
              (l) => l.handler !== trackedHandler
            )
          }
        }
        turboFrame.addEventListener("turbo:frame-missing", trackedHandler, { once: true })
        turboFrame.addEventListener("turbo:fetch-request-error", trackedHandler, { once: true })
        this._attemptsErrorListeners ||= []
        this._attemptsErrorListeners.push(
          { target: turboFrame, event: "turbo:frame-missing", handler: trackedHandler },
          { target: turboFrame, event: "turbo:fetch-request-error", handler: trackedHandler }
        )
        turboFrame.src = attemptsUrl
      }
    } else {
      attemptsContent.classList.add("hidden")
      attemptsChevron.style.transform = "rotate(0deg)"
    }
  }

  toggleVariantPrompts(event) {
    const button = event.currentTarget
    const probeIndex = button.dataset.probeIndex || '0'
    const promptsContent = document.querySelector(`[data-report-redesigned-target="variantPromptsContent"][data-probe-index="${probeIndex}"]`)
    const promptsChevron = document.querySelector(`[data-report-redesigned-target="variantPromptsChevron"][data-probe-index="${probeIndex}"]`)

    if (!promptsContent || !promptsChevron) return

    const isHidden = promptsContent.classList.contains("hidden")

    if (isHidden) {
      promptsContent.classList.remove("hidden")
      promptsChevron.style.transform = "rotate(180deg)"
    } else {
      promptsContent.classList.add("hidden")
      promptsChevron.style.transform = "rotate(0deg)"
    }
  }

  toggleAttemptCard(event) {
    const button = event.currentTarget
    const attemptIndex = button.dataset.attemptIndex
    const attemptContent = document.querySelector(`[data-report-redesigned-target="attemptContent"][data-attempt-index="${attemptIndex}"]`)
    const attemptChevron = document.querySelector(`[data-report-redesigned-target="attemptChevron"][data-attempt-index="${attemptIndex}"]`)

    if (!attemptContent || !attemptChevron) return

    const isHidden = attemptContent.classList.contains("hidden")

    if (isHidden) {
      attemptContent.classList.remove("hidden")
      attemptContent.classList.add("flex")
      attemptChevron.style.transform = "rotate(180deg)"

      // Lazy-load attempt content via Turbo Frame on first expand
      const turboFrame = attemptContent.querySelector("turbo-frame")
      if (turboFrame && !turboFrame.src) {
        const contentUrl = turboFrame.dataset.attemptContentUrl
        const onAttemptError = (e) => {
          e.preventDefault()
          console.error(`[report-redesigned] Failed to load attempt content from ${contentUrl}:`, e)
          turboFrame.removeAttribute("src")  // allow retry on next expand
          turboFrame.innerHTML = '<p class="text-sm text-red-400 p-4 font-sans">Failed to load content. Please try again.</p>'
        }
        turboFrame.addEventListener("turbo:frame-missing", onAttemptError, { once: true })
        turboFrame.addEventListener("turbo:fetch-request-error", onAttemptError, { once: true })
        turboFrame.src = contentUrl
      }
    } else {
      attemptContent.classList.add("hidden")
      attemptContent.classList.remove("flex")
      attemptChevron.style.transform = "rotate(0deg)"
    }
  }

  toggleProbesSection(event) {
    const content = document.querySelector('[data-report-redesigned-target="probesContent"]')
    const chevron = document.querySelector('[data-report-redesigned-target="probesChevron"]')

    if (!content || !chevron) return

    const isHidden = content.classList.contains("hidden")

    if (isHidden) {
      content.classList.remove("hidden")
      chevron.style.transform = "rotate(180deg)"
    } else {
      content.classList.add("hidden")
      chevron.style.transform = "rotate(0deg)"
    }
  }

  /**
   * Sorts probe cards by user-selected criterion.
   * Handles dropdown selection, DOM reordering, and UI updates.
   *
   * @param {Event} event - Click event from dropdown menu item
   */
  sortProbeCards(event) {
    event.preventDefault()
    const sortValue = event.currentTarget.dataset.sortValue
    const sortLabel = event.currentTarget.dataset.sortLabel

    // Update the sort value
    this.sortByValue = sortValue

    // Get the probes container
    const container = this.probesContentTarget.querySelector('.space-y-4')
    if (!container) return

    // Get all probe cards
    const cards = Array.from(container.children)

    // Sort the cards
    const sortedCards = this.applySortToCards(cards, sortValue)

    // Reorder DOM elements efficiently using DocumentFragment
    const fragment = document.createDocumentFragment()
    sortedCards.forEach(card => fragment.appendChild(card))
    container.innerHTML = ''
    container.appendChild(fragment)

    // Update dropdown display
    if (this.hasSortLabelTarget) {
      this.sortLabelTarget.textContent = sortLabel
    }

    // Update checkmark visibility and padding for all menu items
    const menu = event.currentTarget.closest('[data-custom-dropdown-target="menu"]')
    if (menu) {
      const menuItems = menu.querySelectorAll('a')
      menuItems.forEach(item => {
        const itemSortValue = item.dataset.sortValue
        const checkmark = item.querySelector('.icon-check')

        if (itemSortValue === sortValue) {
          if (checkmark) {
            checkmark.classList.remove('hidden')
          }
          item.classList.remove('pl-9', 'pr-3')
          item.classList.add('px-3')
        } else {
          if (checkmark) {
            checkmark.classList.add('hidden')
          }
          item.classList.remove('px-3')
          item.classList.add('pl-9', 'pr-3')
        }
      })
      menu.classList.add('hidden')
    }
  }

  /**
   * Sorts an array of probe card elements by specified criterion.
   * Uses two-tier sorting: primary metric, then ASR as tiebreaker.
   *
   * @param {HTMLElement[]} cards - Array of probe card DOM elements
   * @param {string} sortBy - Sort criterion: 'max_score_desc', 'max_score_asc', 'alphabetical_asc', 'alphabetical_desc'
   * @returns {HTMLElement[]} Sorted array of cards
   */
  applySortToCards(cards, sortBy) {
    return cards.sort((a, b) => {
      let primaryDiff = 0

      // Determine primary sort value based on sort type
      switch (sortBy) {
        case 'max_score_desc':
          // Max Score - highest first (descending)
          primaryDiff = (parseFloat(b.dataset.maxScore) || 0) - (parseFloat(a.dataset.maxScore) || 0)
          break

        case 'max_score_asc':
          // Max Score - lowest first (ascending)
          primaryDiff = (parseFloat(a.dataset.maxScore) || 0) - (parseFloat(b.dataset.maxScore) || 0)
          break

        case 'alphabetical_asc':
          // A - Z (ascending alphabetical)
          const nameA = (a.dataset.probeName || '').toLowerCase()
          const nameB = (b.dataset.probeName || '').toLowerCase()
          primaryDiff = nameA.localeCompare(nameB)
          break

        case 'alphabetical_desc':
          // Z - A (descending alphabetical)
          const nameA_desc = (a.dataset.probeName || '').toLowerCase()
          const nameB_desc = (b.dataset.probeName || '').toLowerCase()
          primaryDiff = nameB_desc.localeCompare(nameA_desc)
          break

        default:
          // Fallback to max_score descending
          primaryDiff = (parseFloat(b.dataset.maxScore) || 0) - (parseFloat(a.dataset.maxScore) || 0)
      }

      // Use ASR as tiebreaker for all sort types (descending)
      if (primaryDiff === 0) {
        const asrA = parseFloat(a.dataset.asr) || 0
        const asrB = parseFloat(b.dataset.asr) || 0
        return asrB - asrA
      }

      return primaryDiff
    })
  }

  copyToClipboard(event) {
    event.stopPropagation()
    const button = event.currentTarget
    const content = button.dataset.content

    if (!content) return

    navigator.clipboard.writeText(content).then(() => {
      const originalSvg = button.innerHTML
      button.innerHTML = `
        <svg class="w-4 h-4 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      `
      setTimeout(() => {
        button.innerHTML = originalSvg
      }, 1500)
    }).catch((err) => {
      console.error('Failed to copy text: ', err)
    })
  }
}
