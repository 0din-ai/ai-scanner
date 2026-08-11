# frozen_string_literal: true

module Reports
  # Stops a running scan report.
  #
  # In multi-pod deployments, the scan may be running on a different pod than
  # where this code executes. Instead of using Process.kill (which only works
  # locally), we set the status to :stopped. The Python HeartbeatThread detects
  # this status change during its next heartbeat cycle and self-terminates.
  #
  # Max termination delay: ~30 seconds (HeartbeatThread interval)
  class Stop
    attr_reader :report

    def initialize(report)
      @report = report
    end

    def call
      report.update(status: :stopped, execution_token: nil)
      Cleanup.new(report).call
      # Widget update handled by Report#broadcast_running_stats_if_needed callback
    end
  end
end
