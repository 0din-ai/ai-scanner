# frozen_string_literal: true

module Admin
  class TargetsController < Admin::BaseController
    include TargetsHelper
    helper ActionView::Helpers::FormTagHelper

    before_action :set_target, only: [ :show, :edit, :update, :destroy, :validate, :restore ]

    def index
      authorize Target
      @page_title = "Targets"
      @show_deleted = params.dig(:q, :deleted_at_not_null) == "1"

      # Handle scoped collection like AA
      base_scope = if params.dig(:q, :deleted_at_not_null) == "1"
        Target.with_deleted.where.not(deleted_at: nil)
      elsif params.dig(:q, :deleted_at_null) == "1"
        Target.all
      else
        Target.all
      end

      @q = base_scope.ransack(params[:q])
      @pagy, @targets = pagy(@q.result.order(created_at: :desc))

      # Load filter options
      @filter_target_types = Target.target_types.map { |k, v| [ k.humanize, v ] }
      @filter_statuses = Target.statuses.map { |k, v| [ k.humanize, v ] }
      @filter_model_types = Target.distinct.pluck(:model_type).compact.sort.map { |t| [ t.titleize, t ] }
    end

    def show
      authorize @target
      @page_title = "Target: #{@target.name}"
      @scheduled_scans = @target.scans.scheduled.includes(:probes, :targets)
    end

    def new
      @target = Target.new
      authorize @target
      @page_title = "New Target"
    end

    def create
      @target = Target.new(target_params)
      authorize @target
      if @target.save
        redirect_to target_path(@target), notice: "Target was successfully created."
      else
        @page_title = "New Target"
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @target
      @page_title = "Edit #{@target.name}"
    end

    def update
      authorize @target
      if @target.update(target_params)
        redirect_to target_path(@target), notice: "Target was successfully updated."
      else
        @page_title = "Edit #{@target.name}"
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @target
      @target.mark_deleted!
      redirect_to targets_path, notice: "Target was successfully archived.", status: :see_other
    end

    def validate
      authorize @target
      @target.validate_target!
      redirect_to target_path(@target), notice: "Target validation started. Check back in a few seconds."
    end

    def restore
      authorize @target
      @target.restore!
      redirect_to target_path(@target), notice: "Target was successfully restored."
    end

    # Unified batch action dispatcher (for shared table component)
    def batch
      authorize Target, :index?
      case params[:batch_action]
      when "validate"
        batch_validate
      when "destroy"
        batch_destroy
      else
        redirect_to targets_path, alert: "Unknown batch action"
      end
    end

    # Batch validate
    def batch_validate
      ids = params[:ids] || []
      valid_targets = Target.where(id: ids).where(deleted_at: nil)
      target_count = valid_targets.count

      if target_count > 0
        valid_targets.find_each do |target|
          ValidateTargetJob.perform_later(target.id)
        end
        redirect_to targets_path, notice: "Validation started for #{target_count} target(s). Check back in a few minutes."
      else
        redirect_to targets_path, alert: "No valid targets selected for validation."
      end
    end

    # Batch action: destroy (soft delete) multiple targets
    def batch_destroy
      ids = params[:ids] || []
      count = 0
      Target.where(id: ids).find_each do |target|
        target.mark_deleted!
        count += 1
      end
      redirect_to targets_path, notice: "#{count} target(s) were successfully archived.", status: :see_other
    end

    # Auto-detect webchat selectors (AJAX)
    def auto_detect_selectors
      authorize Target, :auto_detect_selectors?
      url = params[:url]
      session_id = params[:session_id]

      # Generate signed session_id if not provided (for initial request)
      # Format: cryptographically signed [user_id, uuid] to prevent unauthorized subscriptions
      if session_id.blank?
        uuid = SecureRandom.uuid
        # Sign the session data to prevent tampering
        session_id = Rails.application.message_verifier(:auto_detect_session).generate([ current_user.id, uuid ])
        render json: { session_id: session_id }
        return
      end

      # Verify session_id signature before processing detection request (defense-in-depth)
      begin
        verifier = Rails.application.message_verifier(:auto_detect_session)
        verified_user_id, _uuid = verifier.verify(session_id)

        unless verified_user_id == current_user.id
          render json: { error: "Session does not belong to current user" }, status: :forbidden
          return
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        render json: { error: "Invalid session signature" }, status: :forbidden
        return
      end

      if url.blank?
        render json: { error: "URL is required" }, status: :bad_request
        return
      end

      # Validate URL format and SSRF safety
      safety_result = UrlSafetyValidator.safe_url?(url, allow_localhost: UrlSafetyValidator.allow_localhost?)
      unless safety_result.safe?
        render json: { error: safety_result.error }, status: :bad_request
        return
      end

      # Call auto-detection service with session_id for progress streaming
      detector = AutoDetectWebchatSelectors.new(url, session_id: session_id)
      detection_result = detector.call

      if detection_result
        # Extract selectors and screenshot from detection result
        selectors = detection_result[:selectors]
        screenshot_base64 = detection_result[:screenshot]

        # Build complete config with detected selectors
        response_text_selector = if selectors["response_text"].present?
          selectors["response_text"]
        else
          # Derive from response_container by adding common message selectors
          container = selectors["response_container"]
          "#{container} p, #{container} .message, #{container} [role=\"paragraph\"]"
        end

        config = {
          url: url,
          selectors: selectors,
          wait_times: {
            page_load: 30000,
            response: 30000,
            typing_delay: 50
          },
          detection: {
            response_message_selectors: [ response_text_selector ],
            last_message_selectors: [ "#{response_text_selector}:last-of-type" ],
            skip_patterns: [],
            min_response_length: 5
          }
        }

        render json: { success: true, config: config, screenshot: screenshot_base64 }
      else
        render json: {
          error: "Auto-detection failed. The chat interface could not be detected automatically. Please configure selectors manually.",
          details: "Tried 3 detection attempts but couldn't find valid selectors. The site may require login or use an unusual chat interface."
        }, status: :unprocessable_entity
      end
    rescue StandardError => e
      Rails.logger.error("Auto-detection error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { error: "Detection failed: #{e.message}" }, status: :internal_server_error
    end

    private

    def set_target
      # Allow show/restore to access deleted (archived) targets
      base_scope = %w[show restore].include?(action_name) ? Target.with_deleted : Target
      @target = base_scope.find(params[:id])
    end

    def target_params
      params.require(:target).permit(:name, :model_type, :model, :description, :json_config, :target_type, :web_config)
    end
  end
end
