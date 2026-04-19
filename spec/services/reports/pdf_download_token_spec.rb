require "rails_helper"

RSpec.describe Reports::PdfDownloadToken do
  let(:report_pdf) { instance_double(ReportPdf, id: 42) }
  let(:other_report_pdf) { instance_double(ReportPdf, id: 99) }

  describe ".generate / .verify" do
    it "round-trips a token bound to the report_pdf id" do
      token = described_class.generate(report_pdf)

      expect(described_class.verify(token, report_pdf)).to be(true)
    end

    it "rejects a tampered token" do
      token = described_class.generate(report_pdf)
      tampered = "#{token}tamper"

      expect(described_class.verify(tampered, report_pdf)).to be(false)
    end

    it "rejects an expired token" do
      token = described_class.generate(report_pdf)

      travel_to((described_class::TTL + 1.minute).from_now) do
        expect(described_class.verify(token, report_pdf)).to be(false)
      end
    end

    it "rejects a token generated for a different report_pdf id" do
      token = described_class.generate(other_report_pdf)

      expect(described_class.verify(token, report_pdf)).to be(false)
    end

    it "returns false for blank or nil tokens" do
      expect(described_class.verify(nil, report_pdf)).to be(false)
      expect(described_class.verify("", report_pdf)).to be(false)
      expect(described_class.verify("  ", report_pdf)).to be(false)
    end
  end
end
