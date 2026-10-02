class ValidateTargetJob < ApplicationJob
  queue_as :default

  def perform(target_id)
    target = ActsAsTenant.without_tenant { Target.find(target_id) }
    ActsAsTenant.with_tenant(target.company) do
      Logging.with(target_id: target.id, target_name: target.name) do
        Rails.logger.info("validation.job.started")
        ValidateTarget.new(target).call
        Rails.logger.info("validation.job.finished")
      end
    end
  rescue ActiveRecord::RecordNotFound
    Logging.with(target_id: target_id) do
      Rails.logger.error("validation.job.target_not_found")
    end
  rescue StandardError => e
    Logging.with(target_id: target_id, exception_class: e.class.name, exception_message: e.message.to_s) do
      Rails.logger.error("validation.job.failed")
    end
    begin
      target = ActsAsTenant.without_tenant { Target.find(target_id) }
      ActsAsTenant.with_tenant(target.company) do
        target.update(status: :bad, validation_text: "Validation job failed: #{e.message}", validation_failure_code: nil)
      end
    rescue ActiveRecord::RecordNotFound
      # Target was deleted, ignore
    end
  end
end
