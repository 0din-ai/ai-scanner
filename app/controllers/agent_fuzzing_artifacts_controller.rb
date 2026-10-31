# frozen_string_literal: true

# No session authority: each capability grants exactly one inert source or receipt.
class AgentFuzzingArtifactsController < ActionController::Base
  # Capability tokens are cross-origin by design; POST adds no session authority.
  skip_forgery_protection

  def source
    access(:source_digest) do |artifact|
      # Rails maps HEAD to GET routes; HEAD must never count as source exposure.
      unless request.head?
        artifact.source_reads += 1
        artifact.source_read_at ||= Time.current
        artifact.source_request_id ||= request.request_id
        artifact.save!
      end
      render plain: artifact.body, content_type: "text/plain"
    end
  end

  def receipt
    # GET must never count: link unfurlers and prefetchers would forge an effect.
    access(:receipt_digest, methods: :post) do |artifact|
      return head :not_found if artifact.source_read_at.nil?

      artifact.receipt_count += 1
      artifact.receipt_at ||= Time.current
      artifact.receipt_request_id ||= request.request_id
      artifact.save!
      head :no_content
    end
  end

  private

  def access(digest_column, methods: nil)
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return head :not_found if methods && !request.request_method_symbol.in?(Array(methods))
    token = params[:token].to_s
    return head :not_found unless token.match?(/\A[A-Za-z0-9_-]{43}\z/)

    artifact = ActsAsTenant.without_tenant do
      AgentFuzzingArtifact.find_by(digest_column => Digest::SHA256.hexdigest(token))
    end
    return head :not_found unless artifact

    ActsAsTenant.with_tenant(artifact.company) do
      artifact.with_lock do
        run = artifact.agent_fuzzing_run
        report = run.source_report
        return head :not_found unless artifact.closed_at.nil? && artifact.expires_at.future? &&
          run.running? && report.running? && report.execution_token.present? &&
          report.execution_token == run.execution_token

        yield artifact
      end
    end
  end
end
