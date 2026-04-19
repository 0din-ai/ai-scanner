module Reports
  module PdfDownloadToken
    PURPOSE_PREFIX = "report_pdf_download"
    TTL = 10.minutes

    def self.generate(report_pdf)
      verifier.generate(report_pdf.id,
                        purpose: purpose_for(report_pdf),
                        expires_in: TTL)
    end

    def self.verify(token, report_pdf)
      return false if token.blank?

      verifier.verify(token, purpose: purpose_for(report_pdf)) == report_pdf.id
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      false
    end

    def self.verifier
      Rails.application.message_verifier(:pdf_download)
    end

    def self.purpose_for(report_pdf)
      "#{PURPOSE_PREFIX}:#{report_pdf.id}"
    end

    private_class_method :verifier, :purpose_for
  end
end
