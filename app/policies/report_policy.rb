# frozen_string_literal: true

class ReportPolicy < TenantScopedPolicy
  def stop?
    true
  end

  def asr_history?
    true
  end

  def top_probes?
    true
  end

  def probes_tab?
    true
  end

  def attempt_content?
    true
  end

  def probe_attempts?
    true
  end

  def batch_stop?
    true
  end

  def batch_destroy?
    true
  end
end
