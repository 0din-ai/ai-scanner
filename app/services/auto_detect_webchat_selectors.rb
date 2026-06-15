class AutoDetectWebchatSelectors
  attr_reader :url, :session_id

  # Configuration constants
  MAX_DETECTION_ATTEMPTS = 3
  PAGE_EXTRACTION_WAIT_MS = 8000
  VALIDATION_PAGE_LOAD_MS = 30000
  VALIDATION_RESPONSE_MS = 5000

  # Progress percentages for consistent, non-overlapping progression
  PROGRESS = {
    launching: 10,
    page_loaded: 20,
    analyzing: 30,
    success: 100
  }.freeze

  # Message type categorization for proper broadcast type inference
  PROGRESS_STEPS = [ :launching, :page_loaded, :analyzing, :detecting, :validating ].freeze
  WARNING_STEPS = [ :retry ].freeze
  SUCCESS_STEPS = [ :success ].freeze
  ERROR_STEPS = [ :error ].freeze

  def initialize(url, session_id: nil, auth: nil)
    @url = url
    @session_id = session_id
    @auth = auth
    @current_progress = 0  # Track current progress for error states
  end

  def call
    Rails.logger.info("Starting auto-detection for #{url}")
    broadcast("launching", "🌐 Launching browser and loading page...", progress_for_step(:launching))

    # Step 1: Extract page structure (Phase 2 implementation)
    playwright_service = BrowserAutomation::PlaywrightService.instance
    @page_data = playwright_service.extract_page_structure(url, wait_time: PAGE_EXTRACTION_WAIT_MS, auth: @auth)

    unless @page_data
      Rails.logger.error("Page load failed for #{url}")
      broadcast("error", build_error_message(:page_load_failed), @current_progress)
      cleanup_broadcast  # Signal WebSocket to close
      return nil
    end

    Rails.logger.info("Page structure extracted, analyzing with LLM...")
    broadcast("page_loaded", "✅ Page loaded! Preparing AI analysis...", progress_for_step(:page_loaded))

    # Step 2: Use Phase 1 detection service (75% accuracy)
    broadcast("analyzing", "🤖 Analyzing chat interface with AI (GPT-5)...", progress_for_step(:analyzing))
    detection_service = WebchatSelectorDetectionService.new(url, @page_data)

    # Step 3: Try detection with retry logic (up to MAX_DETECTION_ATTEMPTS)
    attempt = 1
    previous_errors = []

    while attempt <= MAX_DETECTION_ATTEMPTS
      Rails.logger.info("Detection attempt #{attempt}/#{MAX_DETECTION_ATTEMPTS}")
      broadcast("detecting", "🔍 Detection attempt #{attempt}/#{MAX_DETECTION_ATTEMPTS}...", progress_for_step(:detecting, attempt))

      result = detection_service.detect_selectors(
        attempt: attempt,
        previous_errors: previous_errors
      )

      unless result && result[:selectors]
        Rails.logger.error("Detection service returned invalid result on attempt #{attempt}: #{sanitize(result.inspect)}")
        broadcast("error", build_error_message(:exception), @current_progress)
        cleanup_broadcast
        return nil
      end

      # Step 4: Validate with Phase 2 smart waits
      broadcast("validating", "✅ Validating detected selectors...", progress_for_step(:validating, attempt))
      validation = validate_detected_selectors(result[:selectors])

      if validation[:success] && validation[:response_detected]
        Rails.logger.info("Detection successful on attempt #{attempt}")
        broadcast("success", "🎉 Configuration detected successfully!", progress_for_step(:success))
        cleanup_broadcast  # Signal WebSocket to close
        return {
          selectors: result[:selectors],
          screenshot: @page_data["screenshot"]
        }
      else
        Rails.logger.warn("Detection attempt #{attempt} failed: #{sanitize(validation[:errors].to_s)}")
        broadcast("retry", "⚠️ Validation failed. Retrying with different selectors...", progress_for_step(:retry, attempt))
        previous_errors = validation[:errors]
        attempt += 1
      end
    end

    Rails.logger.error("Auto-detection failed after #{MAX_DETECTION_ATTEMPTS} attempts")
    broadcast("error", build_error_message(:max_attempts_exceeded), @current_progress)
    cleanup_broadcast  # Signal WebSocket to close
    nil
  rescue StandardError => e
    Rails.logger.error("Auto-detection failed: #{sanitize(e.message)}")
    Rails.logger.error(sanitize(e.backtrace.join("\n")))
    broadcast("error", build_error_message(:exception), @current_progress)
    cleanup_broadcast  # Signal WebSocket to close
    nil
  end

  private

  # Infer message type from step for proper broadcast categorization
  # @param step [Symbol, String] the step identifier
  # @return [String] the message type ("progress", "warning", "complete", or "error")
  def message_type_for_step(step)
    step_sym = step.to_sym

    return "progress" if PROGRESS_STEPS.include?(step_sym)
    return "warning" if WARNING_STEPS.include?(step_sym)
    return "complete" if SUCCESS_STEPS.include?(step_sym)
    return "error" if ERROR_STEPS.include?(step_sym)

    "progress"  # Default fallback
  end

  # Build contextual error messages with actionable troubleshooting steps
  def build_error_message(context)
    case context
    when :max_attempts_exceeded
      "❌ Auto-detection failed after #{MAX_DETECTION_ATTEMPTS} attempts. " \
      "The chat interface couldn't be detected automatically. " \
      "This usually means: (1) The site requires login before showing chat, " \
      "(2) The chat uses a custom interface, or (3) The site blocks automated browsers. " \
      "Try configuring selectors manually instead."
    when :page_load_failed
      "❌ Unable to load the webpage. " \
      "The page didn't load within #{PAGE_EXTRACTION_WAIT_MS / 1000} seconds. " \
      "Check that: (1) The URL is correct and accessible, " \
      "(2) The site isn't blocking automated access, and " \
      "(3) Your network connection is stable."
    when :exception
      "❌ An unexpected error occurred during detection. " \
      "This might be a temporary issue. Try again, or configure selectors manually if the problem persists."
    else
      "❌ Detection failed. Please try again or configure selectors manually."
    end
  end

  # Calculate progress percentage for attempt-based steps
  # Ensures linear, non-overlapping progression across attempts
  def progress_for_step(step, attempt = 1)
    case step
    when :detecting
      # 45%, 60%, 75% for attempts 1, 2, 3
      30 + (attempt * 15)
    when :validating
      # 55%, 70%, 85% for attempts 1, 2, 3
      30 + (attempt * 15) + 10
    when :retry
      # 50%, 65%, 80% for attempts 1, 2, 3
      30 + (attempt * 15) + 5
    else
      PROGRESS[step] || @current_progress
    end
  end

  def broadcast(step, message, percent)
    return unless session_id.present?

    # Track current progress (used for error states to avoid resetting progress bar)
    @current_progress = percent unless percent.zero?

    ActionCable.server.broadcast("auto_detect_#{session_id}", {
      type: message_type_for_step(step),  # Dynamically infer type from step
      step: step,
      message: message,
      percent: percent,
      timestamp: Time.current.iso8601
    })
  end

  # Send final cleanup signal to close WebSocket connection
  # Prevents memory leaks from orphaned ActionCable streams
  def cleanup_broadcast
    return unless session_id.present?

    ActionCable.server.broadcast("auto_detect_#{session_id}", {
      type: "cleanup",
      timestamp: Time.current.iso8601
    })
  end

  def validate_detected_selectors(selectors)
    service = BrowserAutomation::PlaywrightService.instance

    config = {
      selectors: selectors,
      wait_times: {
        page_load: VALIDATION_PAGE_LOAD_MS,
        response: VALIDATION_RESPONSE_MS
      },
      auth: @auth
    }

    service.validate_webchat_config(url, config)
  end

  def sanitize(text)
    Reports::FailureClassifier.sanitize_text(text.to_s)
  end
end
