require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Reports::PdfStorage do
  describe ".safe_path" do
    let(:sandbox) { File.realpath(Rails.root.join("storage", "pdfs").to_s) }

    it "returns the resolved absolute path for paths inside the sandbox" do
      inside = File.join(sandbox, "report_1.pdf")

      expect(described_class.safe_path(inside)).to eq(inside)
    end

    it "accepts relative paths that resolve inside the sandbox" do
      relative = Rails.root.join("storage", "pdfs", "report_7.pdf").to_s

      expect(described_class.safe_path(relative)).to eq(File.join(sandbox, "report_7.pdf"))
    end

    it "rejects paths that sit outside the sandbox" do
      expect(described_class.safe_path("/etc/passwd")).to be_nil
    end

    it "rejects directory traversal attempts" do
      traversal = File.join(sandbox, "..", "..", "etc", "passwd")

      expect(described_class.safe_path(traversal)).to be_nil
    end

    it "rejects paths whose prefix matches the sandbox but escapes it" do
      sibling = "#{sandbox}_evil/report.pdf"

      expect(described_class.safe_path(sibling)).to be_nil
    end

    it "rejects blank or nil paths" do
      expect(described_class.safe_path(nil)).to be_nil
      expect(described_class.safe_path("")).to be_nil
      expect(described_class.safe_path("   ")).to be_nil
    end

    it "returns nil when the input contains a null byte" do
      expect(described_class.safe_path("#{sandbox}/report.pdf\u0000/evil")).to be_nil
    end

    it "logs a warning when rejecting a path outside the sandbox" do
      expect(Rails.logger).to receive(:warn).with(/Rejected PDF path outside sandbox/)

      described_class.safe_path("/etc/passwd")
    end

    context "with symlink escape attempts" do
      before do
        @tmp_dir = Dir.mktmpdir
        @tmp_root = Pathname.new(File.realpath(@tmp_dir))
        FileUtils.mkdir_p(@tmp_root.join("storage", "pdfs"))
        allow(Rails).to receive(:root).and_return(@tmp_root)
      end

      after do
        FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.exist?(@tmp_dir)
      end

      let(:tmp_sandbox) { File.realpath(@tmp_root.join("storage", "pdfs").to_s) }

      it "rejects a symlink inside the sandbox that points to a file outside" do
        outside_target = File.join(@tmp_root, "secret.txt")
        File.write(outside_target, "secret")
        link = File.join(tmp_sandbox, "sneak.pdf")
        File.symlink(outside_target, link)

        expect(Rails.logger).to receive(:warn).with(/Rejected PDF path outside sandbox/)
        expect(described_class.safe_path(link)).to be_nil
      end

      it "rejects paths whose parent directory is a symlink pointing outside the sandbox" do
        outside_dir = File.join(@tmp_root, "evil")
        FileUtils.mkdir_p(outside_dir)
        parent_link = File.join(tmp_sandbox, "evil_link")
        File.symlink(outside_dir, parent_link)

        expect(described_class.safe_path(File.join(parent_link, "report.pdf"))).to be_nil
      end

      it "rejects broken symlinks that could later become escape vectors" do
        link = File.join(tmp_sandbox, "broken.pdf")
        File.symlink("/definitely/does/not/exist", link)

        expect(described_class.safe_path(link)).to be_nil
      end

      it "allows in-sandbox symlinks pointing to files inside the sandbox" do
        real = File.join(tmp_sandbox, "real.pdf")
        File.write(real, "pdf")
        link = File.join(tmp_sandbox, "link.pdf")
        File.symlink(real, link)

        expect(described_class.safe_path(link)).to eq(real)
      end

      it "accepts non-existent files whose parent is the real sandbox" do
        future_file = File.join(tmp_sandbox, "future.pdf")

        expect(described_class.safe_path(future_file)).to eq(future_file)
      end

      it "accepts in-sandbox paths even when storage/pdfs does not exist yet" do
        FileUtils.rm_rf(@tmp_root.join("storage"))
        future_file = @tmp_root.join("storage", "pdfs", "future.pdf").to_s

        expect(described_class.safe_path(future_file)).to eq(future_file)
      end
    end
  end
end
