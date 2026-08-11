# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::Stop do
  let(:target) { create(:target, status: "good") }
  let(:scan) { create(:complete_scan) }

  before do
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    # Force scan creation, then clean up auto-created reports
    scan
    Report.delete_all
  end

  let(:report) { create(:report, scan: scan, target: target, status: :running, heartbeat_at: Time.current) }

  describe "#call" do
    it "revokes the execution token so the scanner process cannot keep writing" do
      report.update!(execution_token: SecureRandom.uuid)

      described_class.new(report).call

      expect(report.reload.execution_token).to be_nil
    end

    it "changes report status to stopped" do
      described_class.new(report).call
      expect(report.reload.status).to eq("stopped")
    end

    it "calls cleanup" do
      cleanup = instance_double(Reports::Cleanup)
      allow(Reports::Cleanup).to receive(:new).with(report).and_return(cleanup)
      expect(cleanup).to receive(:call)

      described_class.new(report).call
    end

    it "does not use Process.kill (multi-pod safe)" do
      report.update(pid: 12345)
      expect(Process).not_to receive(:kill)

      described_class.new(report).call
    end

    it "triggers broadcast callback via status change" do
      expect(BroadcastRunningStatsJob).to receive(:perform_later).at_least(:once)

      described_class.new(report).call
    end

    context "when report is already stopped" do
      let(:report) { create(:report, scan: scan, target: target, status: :stopped) }

      it "remains stopped" do
        described_class.new(report).call
        expect(report.reload.status).to eq("stopped")
      end
    end

    context "when report is pending" do
      let(:report) { create(:report, scan: scan, target: target, status: :pending) }

      it "changes status to stopped" do
        described_class.new(report).call
        expect(report.reload.status).to eq("stopped")
      end
    end

    context "when report is starting" do
      let(:report) { create(:report, scan: scan, target: target, status: :starting) }

      it "changes status to stopped" do
        described_class.new(report).call
        expect(report.reload.status).to eq("stopped")
      end
    end
  end
end
