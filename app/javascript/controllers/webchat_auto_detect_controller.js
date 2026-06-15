import { Controller } from "@hotwired/stimulus";
import consumer from "channels/consumer";

export default class extends Controller {
  static targets = [
    "detectButton",
    "buttonText",
    "message",
    "progressBar",
    "progressContainer",
  ];

  // Constants for configuration and timeouts
  static CONNECTION_TIMEOUT_MS = 5000; // WebSocket connection timeout

  connect() {
    this.urlInput = document.querySelector('input[name="web_chat_url"]');
    this.configTextarea = document.querySelector(
      'textarea[name="target[web_config]"]',
    );
    this.subscription = null;

    // Initialize ARIA attributes for accessibility
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.setAttribute("role", "progressbar");
      this.progressBarTarget.setAttribute("aria-valuemin", "0");
      this.progressBarTarget.setAttribute("aria-valuemax", "100");
      this.progressBarTarget.setAttribute("aria-valuenow", "0");
      this.progressBarTarget.setAttribute(
        "aria-label",
        "Webchat selector detection progress",
      );
    }
  }

  disconnect() {
    // Clear pending connection timeout to prevent memory leak
    if (this.connectionTimeout) {
      clearTimeout(this.connectionTimeout);
      this.connectionTimeout = null;
    }

    // Cleanup subscription when controller disconnects
    if (this.subscription) {
      this.subscription.unsubscribe();
      this.subscription = null;
    }
  }

  currentAuth() {
    try {
      const config = JSON.parse(this.configTextarea?.value || "{}")
      return config && config.auth ? config.auth : null
    } catch (_) {
      return null
    }
  }

  async detect(event) {
    event.preventDefault();

    const url = this.urlInput?.value?.trim();

    if (!url) {
      this.showError("Please enter a Chat URL first");
      return;
    }

    this.setLoading(true);
    this.hideMessage();
    this.showProgressBar();

    try {
      // Phase 1: Get session_id from backend
      const initResponse = await fetch("/targets/auto_detect_selectors", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.getCSRFToken(),
        },
        body: JSON.stringify({ url: url }),
      });

      const initData = await initResponse.json();

      if (!initResponse.ok || !initData.session_id) {
        this.showError(initData.error || "Failed to initialize detection");
        this.hideProgressBar();
        return;
      }

      const sessionId = initData.session_id;

      // Phase 2: Subscribe to progress updates via ActionCable and wait for connection
      try {
        await this.subscribeToProgress(sessionId);
      } catch (error) {
        console.error("Failed to establish WebSocket connection:", error);
        const errorMsg = this.getWebSocketErrorMessage(error);
        this.showError(errorMsg);
        // Continue with detection even if WebSocket fails
      }

      // Phase 3: Start actual detection with session_id
      const response = await fetch("/targets/auto_detect_selectors", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.getCSRFToken(),
        },
        body: JSON.stringify({ url: url, session_id: sessionId, auth: this.currentAuth() }),
      });

      const data = await response.json();

      if (response.ok && data.success) {
        this.configTextarea.value = JSON.stringify(data.config, null, 2);
        this.configTextarea.dispatchEvent(
          new Event("input", { bubbles: true }),
        );

        // Display screenshot if available
        if (data.screenshot) {
          this.showSuccessWithScreenshot(data.screenshot);
        } else {
          this.showSuccess(
            "Selectors detected successfully! Review the configuration below.",
          );
        }
      } else {
        this.showError(data.error || "Detection failed");
      }
    } catch (error) {
      console.error("Auto-detection error:", error);
      const errorMsg =
        "🌐 Network error occurred. " +
        "Check your internet connection and try again. " +
        "If the problem persists, the server may be temporarily unavailable.";
      this.showError(errorMsg);
    } finally {
      this.setLoading(false);
      this.hideProgressBar();
      // Note: Subscription cleanup is handled by updateProgress()
      // for error/complete message types, and in disconnect() for navigation
    }
  }

  setLoading(isLoading) {
    if (isLoading) {
      this.detectButtonTarget.disabled = true;
      this.detectButtonTarget.classList.add("opacity-75", "cursor-not-allowed");
      this.buttonTextTarget.textContent = "Detecting...";
    } else {
      this.detectButtonTarget.disabled = false;
      this.detectButtonTarget.classList.remove(
        "opacity-75",
        "cursor-not-allowed",
      );
      this.buttonTextTarget.textContent = "Auto-Detect Selectors with AI";
    }
  }

  showSuccess(message) {
    this.messageTarget.classList.remove("hidden");
    this.messageTarget.className = this.getMessageClasses("success");

    const wrapper = document.createElement("div");
    wrapper.className = "flex items-start";
    wrapper.appendChild(this.createSuccessIcon());

    const span = document.createElement("span");
    span.textContent = message; // Safe - textContent auto-escapes HTML
    wrapper.appendChild(span);

    this.messageTarget.replaceChildren(wrapper);
  }

  showSuccessWithScreenshot(base64Screenshot) {
    this.messageTarget.classList.remove("hidden");
    // Use larger padding for screenshot display
    this.messageTarget.className = `mt-3 p-4 rounded-lg border ${this.getMessageColorClasses("success")}`;

    // Build container
    const container = document.createElement("div");
    container.className = "space-y-3";

    // Header section with icon and text
    const headerDiv = document.createElement("div");
    headerDiv.className = "flex items-start";

    const icon = this.createSuccessIcon();
    icon.classList.add("text-green-600", "dark:text-green-400");
    headerDiv.appendChild(icon);

    const textDiv = document.createElement("div");
    const title = document.createElement("p");
    title.className = "text-sm font-semibold text-green-700 dark:text-green-300";
    title.textContent = "Configuration Detected Successfully!";
    textDiv.appendChild(title);

    const subtitle = document.createElement("p");
    subtitle.className = "text-xs text-green-600 dark:text-green-400 mt-1";
    subtitle.textContent = "Review the generated configuration and screenshot below.";
    textDiv.appendChild(subtitle);

    headerDiv.appendChild(textDiv);
    container.appendChild(headerDiv);

    // Screenshot section
    const screenshotSection = document.createElement("div");
    screenshotSection.className = "border-t border-green-200 dark:border-green-700 pt-3";

    const previewLabel = document.createElement("p");
    previewLabel.className = "text-xs font-medium text-green-700 dark:text-green-300 mb-2";
    previewLabel.textContent = "Preview of detected chat interface:";
    screenshotSection.appendChild(previewLabel);

    const img = document.createElement("img");
    img.src = `data:image/png;base64,${base64Screenshot}`; // Safe - src attribute
    img.alt = "Webchat Screenshot";
    img.className = "w-full rounded-lg border-2 border-green-300 dark:border-green-600 shadow-md cursor-pointer hover:shadow-lg transition-shadow";
    img.style.cssText = "max-height: 300px; object-fit: contain; background: white;";
    img.addEventListener("click", () => window.open(img.src, "_blank"));
    screenshotSection.appendChild(img);

    const clickHint = document.createElement("p");
    clickHint.className = "text-xs text-green-600 dark:text-green-400 mt-1 text-center";
    clickHint.textContent = "Click to view full size";
    screenshotSection.appendChild(clickHint);

    container.appendChild(screenshotSection);
    this.messageTarget.replaceChildren(container);
  }

  showError(message) {
    this.messageTarget.classList.remove("hidden");
    this.messageTarget.className = this.getMessageClasses("error");

    const wrapper = document.createElement("div");
    wrapper.className = "flex items-start";
    wrapper.appendChild(this.createErrorIcon());

    const span = document.createElement("span");
    span.textContent = message; // Safe - textContent auto-escapes HTML
    wrapper.appendChild(span);

    this.messageTarget.replaceChildren(wrapper);
  }

  hideMessage() {
    this.messageTarget.classList.add("hidden");
  }

  subscribeToProgress(sessionId) {
    // Unsubscribe from any existing subscription
    if (this.subscription) {
      this.subscription.unsubscribe();
    }

    // Return a Promise that resolves when connection is established
    return new Promise((resolve, reject) => {
      // Store timeout reference for cleanup in disconnect()
      this.connectionTimeout = setTimeout(() => {
        this.connectionTimeout = null; // Clear reference
        reject(
          new Error(
            `WebSocket connection timeout after ${this.constructor.CONNECTION_TIMEOUT_MS}ms`,
          ),
        );
      }, this.constructor.CONNECTION_TIMEOUT_MS);

      // Create new subscription for this detection session
      this.subscription = consumer.subscriptions.create(
        { channel: "AutoDetectChannel", session_id: sessionId },
        {
          connected: () => {
            if (this.connectionTimeout) {
              clearTimeout(this.connectionTimeout);
              this.connectionTimeout = null; // Clear reference
            }
            resolve(); // Connection established successfully
          },
          disconnected: () => {
          },
          rejected: () => {
            if (this.connectionTimeout) {
              clearTimeout(this.connectionTimeout);
              this.connectionTimeout = null; // Clear reference
            }
            console.error("ActionCable subscription rejected");
            reject(new Error("WebSocket subscription rejected by server"));
          },
          received: (data) => {
            this.updateProgress(data);
          },
        },
      );
    });
  }

  updateProgress(data) {
    switch (data.type) {
      case "progress":
        // Update progress bar with accessibility support
        if (this.hasProgressBarTarget) {
          this.progressBarTarget.style.width = `${data.percent}%`;
          this.progressBarTarget.setAttribute("aria-valuenow", data.percent);
          // Provide meaningful text for screen readers
          this.progressBarTarget.setAttribute(
            "aria-valuetext",
            `${data.percent}% - ${data.message}`,
          );
        }
        // Show progress message
        this.showProgressMessage(data.message, data.step);
        break;

      case "warning":
        // Show warning message but keep progress bar
        if (this.hasProgressBarTarget) {
          this.progressBarTarget.style.width = `${data.percent}%`;
          this.progressBarTarget.setAttribute("aria-valuenow", data.percent);
          this.progressBarTarget.setAttribute(
            "aria-valuetext",
            `${data.percent}% - ${data.message}`,
          );
        }
        this.showWarningMessage(data.message);
        break;

      case "complete":
        this.cleanupSubscription();
        break;

      case "error":
        // Show error and cleanup subscription
        this.showError(data.message);
        this.cleanupSubscription();
        break;

      case "cleanup":
        // Final cleanup signal from server
        this.cleanupSubscription();
        break;

      default:
        console.warn("Unknown broadcast message type:", data.type, data);
    }
  }

  showProgressMessage(message, step) {
    if (!this.hasMessageTarget) return;

    this.messageTarget.classList.remove("hidden");
    this.messageTarget.className = this.getMessageClasses("info");

    const wrapper = document.createElement("div");
    wrapper.className = "flex items-start";
    wrapper.appendChild(this.createSpinnerIcon());

    const span = document.createElement("span");
    span.textContent = message; // Safe - textContent auto-escapes HTML
    wrapper.appendChild(span);

    this.messageTarget.replaceChildren(wrapper);
  }

  showWarningMessage(message) {
    if (!this.hasMessageTarget) return;

    this.messageTarget.classList.remove("hidden");
    this.messageTarget.className = this.getMessageClasses("warning");

    const wrapper = document.createElement("div");
    wrapper.className = "flex items-start";
    wrapper.appendChild(this.createWarningIcon());

    const span = document.createElement("span");
    span.textContent = message; // Safe - textContent auto-escapes HTML
    wrapper.appendChild(span);

    this.messageTarget.replaceChildren(wrapper);
  }

  showProgressBar() {
    if (this.hasProgressContainerTarget) {
      this.progressContainerTarget.classList.remove("hidden");

      // Reset progress bar to 0%
      if (this.hasProgressBarTarget) {
        this.progressBarTarget.style.width = "0%";
        this.progressBarTarget.setAttribute("aria-valuenow", "0");
      }
    }
  }

  hideProgressBar() {
    if (this.hasProgressContainerTarget) {
      this.progressContainerTarget.classList.add("hidden");
    }
  }

  getCSRFToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }

  // CSS utility methods for consistent styling
  getMessageBaseClasses() {
    return "mt-2 p-3 rounded-lg border text-sm";
  }

  getMessageColorClasses(type) {
    const colors = {
      success:
        "bg-green-50 dark:bg-green-900/30 border-green-200 dark:border-green-700 text-green-700 dark:text-green-300",
      error:
        "bg-red-50 dark:bg-red-900/30 border-red-200 dark:border-red-700 text-red-700 dark:text-red-300",
      info: "bg-blue-50 dark:bg-blue-900/30 border-blue-200 dark:border-blue-700 text-blue-700 dark:text-blue-300",
      warning:
        "bg-yellow-50 dark:bg-yellow-900/30 border-yellow-200 dark:border-yellow-700 text-yellow-700 dark:text-yellow-300",
    };
    return colors[type] || colors.info;
  }

  getMessageClasses(type) {
    return `${this.getMessageBaseClasses()} ${this.getMessageColorClasses(type)}`;
  }

  // SVG icon factory methods - create icons programmatically to avoid innerHTML XSS
  createSuccessIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "w-5 h-5 mr-2 shrink-0");
    svg.setAttribute("fill", "currentColor");
    svg.setAttribute("viewBox", "0 0 20 20");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill-rule", "evenodd");
    path.setAttribute(
      "d",
      "M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z",
    );
    svg.appendChild(path);

    return svg;
  }

  createErrorIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "w-5 h-5 mr-2 shrink-0");
    svg.setAttribute("fill", "currentColor");
    svg.setAttribute("viewBox", "0 0 20 20");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill-rule", "evenodd");
    path.setAttribute(
      "d",
      "M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z",
    );
    svg.appendChild(path);

    return svg;
  }

  createSpinnerIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "w-5 h-5 mr-2 shrink-0 animate-spin");
    svg.setAttribute("fill", "none");
    svg.setAttribute("viewBox", "0 0 24 24");

    const circle = document.createElementNS(
      "http://www.w3.org/2000/svg",
      "circle",
    );
    circle.setAttribute("class", "opacity-25");
    circle.setAttribute("cx", "12");
    circle.setAttribute("cy", "12");
    circle.setAttribute("r", "10");
    circle.setAttribute("stroke", "currentColor");
    circle.setAttribute("stroke-width", "4");
    svg.appendChild(circle);

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("class", "opacity-75");
    path.setAttribute("fill", "currentColor");
    path.setAttribute(
      "d",
      "M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z",
    );
    svg.appendChild(path);

    return svg;
  }

  createWarningIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "w-5 h-5 mr-2 shrink-0");
    svg.setAttribute("fill", "currentColor");
    svg.setAttribute("viewBox", "0 0 20 20");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill-rule", "evenodd");
    path.setAttribute(
      "d",
      "M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z",
    );
    svg.appendChild(path);

    return svg;
  }

  // Get contextual error message for WebSocket connection failures
  getWebSocketErrorMessage(error) {
    const message = error.message || "";

    if (message.includes("timeout")) {
      return (
        `⏱️ Connection timeout after ${this.constructor.CONNECTION_TIMEOUT_MS / 1000} seconds. ` +
        "The server may be slow or unreachable. Check your internet connection and try again."
      );
    } else if (message.includes("rejected")) {
      return "🔒 Connection rejected by server. Your session may have expired. Refresh the page and try again.";
    } else {
      return (
        "🌐 Failed to establish real-time connection. The detection will proceed without live progress updates. " +
        "If this persists, check your internet connection."
      );
    }
  }

  // Clean up WebSocket subscription to prevent memory leaks
  cleanupSubscription() {
    if (this.subscription) {
      this.subscription.unsubscribe();
      this.subscription = null;
    }
  }
}
