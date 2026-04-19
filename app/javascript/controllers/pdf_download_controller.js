import { Controller } from "@hotwired/stimulus"
import { showToast } from "utils"

const POLL_INTERVAL_MS = 5000
const POLL_TIMEOUT_MS = 3 * 60 * 1000

export default class extends Controller {
  static targets = ["button", "text", "icon"]
  static values = {
    reportId: String,
    url: String
  }

  connect() {
    this.downloadRequested = false
    this.pollingTimer = null
    this.pollingStartedAt = null
    this.autoRetryConsumed = false
    this.statusUrl = null

    const statusDiv = document.getElementById(`pdf-status-${this.reportIdValue}`)
    if (statusDiv && statusDiv.parentElement) {
      this.observer = new MutationObserver(() => {
        const updatedStatusDiv = document.getElementById(`pdf-status-${this.reportIdValue}`)
        if (updatedStatusDiv) {
          this.checkPdfStatus(updatedStatusDiv)
        }
      })
      this.observer.observe(statusDiv.parentElement, {
        childList: true,
        subtree: true
      })
    }
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
    this.stopPollingFallback()
  }

  async downloadPdf(event) {
    event.preventDefault()

    const button = event.currentTarget
    const statusUrl = button.dataset.pdfDownloadUrlValue || this.urlValue || button.href

    if (!statusUrl) {
      console.error("No PDF URL found")
      this.showError("PDF URL not configured")
      return
    }

    this.downloadRequested = true
    this.autoRetryConsumed = false
    this.statusUrl = statusUrl
    this.setLoading(true)

    try {
      await this.requestPdf(statusUrl)
    } catch (error) {
      console.error("PDF download error:", error)
      this.downloadRequested = false
      this.showError("Failed to download PDF")
    }
  }

  async requestPdf(statusUrl) {
    const response = await fetch(statusUrl, {
      headers: { "Accept": "application/json" }
    })

    if (response.status === 200) {
      const data = await response.json()
      if (data.status === "ready" && data.download_url) {
        this.triggerDownload(data.download_url)
      } else {
        this.downloadRequested = false
        this.showError(data.message || "PDF is not ready")
      }
      return
    }

    if (response.status === 202) {
      const data = await response.json().catch(() => ({}))
      this.showGenerating(data.message || "Generating PDF...")
      this.startPollingFallback(statusUrl)
      return
    }

    const data = await response.json().catch(() => ({}))

    if (data && data.retryable && data.retry_url && !this.autoRetryConsumed) {
      this.autoRetryConsumed = true
      await this.retryPdf(data.retry_url, statusUrl)
      return
    }

    this.downloadRequested = false
    this.showError(data.message || data.error || "Failed to generate PDF")
  }

  async retryPdf(retryUrl, statusUrl) {
    const response = await fetch(retryUrl, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken(),
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })

    const data = await response.json().catch(() => ({}))

    if (response.status === 202) {
      this.showGenerating(data.message || "Retrying PDF generation...")
      this.startPollingFallback(statusUrl)
      return
    }

    if (response.status === 200 && data.status === "ready" && data.download_url) {
      this.triggerDownload(data.download_url)
      return
    }

    this.downloadRequested = false
    this.showError(data.message || data.error || "Failed to retry PDF generation")
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  checkPdfStatus(statusDiv) {
    if (!this.downloadRequested) return

    const status = statusDiv.dataset.pdfStatus
    const downloadUrl = statusDiv.dataset.downloadUrl
    const errorMessage = statusDiv.dataset.pdfError
    const retryUrl = statusDiv.dataset.retryUrl
    const retryable = statusDiv.dataset.pdfRetryable === "true"

    if (status === "ready" && downloadUrl) {
      this.triggerDownload(downloadUrl)
    } else if (status === "failed") {
      if (retryable && retryUrl && this.statusUrl && !this.autoRetryConsumed) {
        this.autoRetryConsumed = true
        this.stopPollingFallback()
        this.retryPdf(retryUrl, this.statusUrl).catch((error) => {
          console.error("PDF retry error:", error)
          this.downloadRequested = false
          this.showError("Failed to retry PDF generation")
        })
        return
      }

      this.stopPollingFallback()
      this.downloadRequested = false
      this.showError(errorMessage || "PDF generation failed")
    }
  }

  triggerDownload(url) {
    this.stopPollingFallback()
    this.downloadRequested = false
    this.setLoading(false)
    window.location.href = url
  }

  startPollingFallback(statusUrl) {
    this.stopPollingFallback()
    this.pollingStartedAt = Date.now()

    this.pollingTimer = setInterval(async () => {
      if (!this.downloadRequested) {
        this.stopPollingFallback()
        return
      }

      if (Date.now() - this.pollingStartedAt > POLL_TIMEOUT_MS) {
        this.stopPollingFallback()
        this.downloadRequested = false
        this.showError("PDF generation timed out. Please try again.")
        return
      }

      try {
        const response = await fetch(statusUrl, {
          headers: { "Accept": "application/json" }
        })

        if (response.status === 200) {
          const data = await response.json()
          if (data.status === "ready" && data.download_url) {
            this.triggerDownload(data.download_url)
          }
        } else if (response.status !== 202) {
          const data = await response.json().catch(() => ({}))

          if (data && data.retryable && data.retry_url && !this.autoRetryConsumed) {
            this.autoRetryConsumed = true
            this.stopPollingFallback()
            await this.retryPdf(data.retry_url, statusUrl)
            return
          }

          this.stopPollingFallback()
          this.downloadRequested = false
          this.showError(data.message || data.error || "PDF generation failed")
        }
      } catch (error) {
        console.error("PDF polling error:", error)
      }
    }, POLL_INTERVAL_MS)
  }

  stopPollingFallback() {
    if (this.pollingTimer) {
      clearInterval(this.pollingTimer)
      this.pollingTimer = null
    }
    this.pollingStartedAt = null
  }

  setLoading(loading) {
    if (!this.hasButtonTarget) return

    if (loading) {
      this.buttonTarget.classList.add("opacity-50", "pointer-events-none")
      if (this.hasTextTarget) {
        this.originalText = this.textTarget.textContent
        this.textTarget.textContent = "Preparing..."
      } else {
        this.originalText = this.buttonTarget.textContent.trim()
        Array.from(this.buttonTarget.childNodes).forEach(node => {
          if (node.nodeType === Node.TEXT_NODE && node.textContent.trim()) {
            node.textContent = " Preparing..."
          }
        })
      }
    } else {
      this.buttonTarget.classList.remove("opacity-50", "pointer-events-none")
      if (this.hasTextTarget) {
        this.textTarget.textContent = this.originalText || "Download PDF"
      } else {
        Array.from(this.buttonTarget.childNodes).forEach(node => {
          if (node.nodeType === Node.TEXT_NODE && node.textContent.trim()) {
            const labelOnly = this.originalText ? this.originalText.replace(/^\s+/, " ") : " Download PDF"
            node.textContent = labelOnly
          }
        })
      }
    }
  }

  showGenerating(message) {
    if (this.hasTextTarget) {
      this.textTarget.textContent = message
    }
  }

  showError(message) {
    if (this.hasTextTarget) {
      this.textTarget.textContent = "Download PDF"
    }
    this.setLoading(false)
    console.error("PDF download error:", message)
    showToast(message, "error")
  }
}
