# frozen_string_literal: true

require "rails_helper"

RSpec.describe UrlSafetyValidator do
  describe ".safe_url?" do
    context "with safe external URLs" do
      it "allows standard HTTPS URLs" do
        result = described_class.safe_url?("https://example.com")
        expect(result.safe?).to be true
      end

      it "allows standard HTTP URLs" do
        result = described_class.safe_url?("http://example.com/path")
        expect(result.safe?).to be true
      end

      it "allows URLs with ports" do
        result = described_class.safe_url?("https://example.com:8443/api")
        expect(result.safe?).to be true
      end
    end

    context "with loopback addresses" do
      it "blocks http://127.0.0.1" do
        result = described_class.safe_url?("http://127.0.0.1")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks http://127.0.0.2" do
        result = described_class.safe_url?("http://127.0.0.2")
        expect(result.safe?).to be false
      end

      it "blocks http://[::1]" do
        result = described_class.safe_url?("http://[::1]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end
    end

    context "with RFC1918 private addresses" do
      it "blocks http://10.0.0.1" do
        result = described_class.safe_url?("http://10.0.0.1")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks http://172.16.0.1" do
        result = described_class.safe_url?("http://172.16.0.1")
        expect(result.safe?).to be false
      end

      it "blocks http://192.168.1.1" do
        result = described_class.safe_url?("http://192.168.1.1")
        expect(result.safe?).to be false
      end

      it "allows http://172.32.0.1 (outside /12 range)" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("172.32.0.1").and_return([ "172.32.0.1" ])
        result = described_class.safe_url?("http://172.32.0.1")
        expect(result.safe?).to be true
      end
    end

    context "with cloud metadata endpoints" do
      it "blocks http://169.254.169.254" do
        result = described_class.safe_url?("http://169.254.169.254")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks http://169.254.169.254/latest/meta-data" do
        result = described_class.safe_url?("http://169.254.169.254/latest/meta-data")
        expect(result.safe?).to be false
      end
    end

    context "with non-HTTP schemes" do
      it "blocks FTP URLs" do
        result = described_class.safe_url?("ftp://example.com")
        expect(result.safe?).to be false
        expect(result.error).to include("Only HTTP and HTTPS")
      end

      it "blocks javascript URIs" do
        result = described_class.safe_url?("javascript:alert(1)")
        expect(result.safe?).to be false
      end
    end

    context "with invalid input" do
      it "rejects nil" do
        result = described_class.safe_url?(nil)
        expect(result.safe?).to be false
      end

      it "rejects empty string" do
        result = described_class.safe_url?("")
        expect(result.safe?).to be false
      end

      it "rejects malformed URLs" do
        result = described_class.safe_url?("not a url at all")
        expect(result.safe?).to be false
      end
    end

    context "with allow_localhost option" do
      it "allows localhost IP when allow_localhost is true" do
        result = described_class.safe_url?("http://127.0.0.1:3000", allow_localhost: true)
        expect(result.safe?).to be true
      end

      it "allows localhost hostname when allow_localhost is true" do
        result = described_class.safe_url?("http://localhost:3000", allow_localhost: true)
        expect(result.safe?).to be true
      end

      it "still blocks private ranges when allow_localhost is true" do
        result = described_class.safe_url?("http://10.0.0.1", allow_localhost: true)
        expect(result.safe?).to be false
      end

      it "still blocks metadata endpoint when allow_localhost is true" do
        result = described_class.safe_url?("http://169.254.169.254", allow_localhost: true)
        expect(result.safe?).to be false
      end
    end

    context "with DNS resolution" do
      it "blocks hostnames that resolve to internal IPs" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("evil.example.com").and_return([ "127.0.0.1" ])
        result = described_class.safe_url?("http://evil.example.com")
        expect(result.safe?).to be false
      end

      it "blocks hostnames that resolve to private IPs" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("internal.example.com").and_return([ "192.168.1.100" ])
        result = described_class.safe_url?("http://internal.example.com")
        expect(result.safe?).to be false
      end

      it "blocks hostnames that cannot be resolved" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("nonexistent.invalid").and_return([])
        result = described_class.safe_url?("http://nonexistent.invalid")
        expect(result.safe?).to be false
        expect(result.error).to eq("Could not resolve hostname")
      end
    end

    context "with IPv6 addresses" do
      it "blocks IPv6 unique local addresses" do
        result = described_class.safe_url?("http://[fd00::1]")
        expect(result.safe?).to be false
      end

      it "blocks IPv6 link-local addresses" do
        result = described_class.safe_url?("http://[fe80::1]")
        expect(result.safe?).to be false
      end
    end

    context "with IPv4-mapped IPv6 addresses" do
      it "blocks ::ffff:127.0.0.1 (mapped loopback)" do
        result = described_class.safe_url?("http://[::ffff:127.0.0.1]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks ::ffff:169.254.169.254 (mapped metadata)" do
        result = described_class.safe_url?("http://[::ffff:169.254.169.254]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks ::ffff:10.0.0.1 (mapped RFC1918)" do
        result = described_class.safe_url?("http://[::ffff:10.0.0.1]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks ::ffff:192.168.1.1 (mapped RFC1918)" do
        result = described_class.safe_url?("http://[::ffff:192.168.1.1]")
        expect(result.safe?).to be false
      end

      it "blocks hostnames resolving to IPv4-mapped addresses" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("mapped.evil.com").and_return([ "::ffff:127.0.0.1" ])
        result = described_class.safe_url?("http://mapped.evil.com")
        expect(result.safe?).to be false
      end

      it "allows ::ffff:127.0.0.1 when allow_localhost is true" do
        result = described_class.safe_url?("http://[::ffff:127.0.0.1]:3000", allow_localhost: true)
        expect(result.safe?).to be true
      end
    end

    context "with zero address" do
      it "blocks http://0.0.0.0" do
        result = described_class.safe_url?("http://0.0.0.0")
        expect(result.safe?).to be false
      end
    end

    context "with additional blocked ranges" do
      it "blocks CGN shared address space (100.64.0.1)" do
        result = described_class.safe_url?("http://100.64.0.1")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks reserved-for-future (240.0.0.1)" do
        result = described_class.safe_url?("http://240.0.0.1")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks multicast (224.0.0.1)" do
        result = described_class.safe_url?("http://224.0.0.1")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks broadcast (255.255.255.255)" do
        result = described_class.safe_url?("http://255.255.255.255")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks IPv6 unspecified ([::])" do
        result = described_class.safe_url?("http://[::]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end

      it "blocks IPv6 multicast ([ff02::1])" do
        result = described_class.safe_url?("http://[ff02::1]")
        expect(result.safe?).to be false
        expect(result.error).to include("blocked internal address")
      end
    end

    context "with URI userinfo" do
      it "rejects URLs with user credentials" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("example.com").and_return([ "93.184.216.34" ])
        result = described_class.safe_url?("http://user@example.com/")
        expect(result.safe?).to be false
        expect(result.error).to include("credentials")
      end

      it "rejects URLs with user:password credentials" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("example.com").and_return([ "93.184.216.34" ])
        result = described_class.safe_url?("http://user:pass@example.com/")
        expect(result.safe?).to be false
        expect(result.error).to include("credentials")
      end
    end

    context "with IPv6 zone IDs" do
      it "rejects URLs with percent-encoded zone IDs" do
        result = described_class.safe_url?("http://[fe80::1%25eth0]/")
        expect(result.safe?).to be false
      end

      it "rejects URLs with unencoded zone IDs" do
        result = described_class.safe_url?("http://[fe80::1%eth0]/")
        expect(result.safe?).to be false
      end
    end

    context "with DNS resolution timeout" do
      it "configures DNS resolver with timeouts" do
        resolver = instance_double(Resolv::DNS)
        allow(Resolv::DNS).to receive(:new).and_return(resolver)
        allow(resolver).to receive(:timeouts=)
        allow(resolver).to receive(:getaddresses).with("slow.example.com").and_return([])
        allow(resolver).to receive(:close)

        described_class.resolve_addresses("slow.example.com")

        expect(resolver).to have_received(:timeouts=).with([ 2, 2 ])
      end

      it "returns empty array on DNS resolution error" do
        resolver = instance_double(Resolv::DNS)
        allow(Resolv::DNS).to receive(:new).and_return(resolver)
        allow(resolver).to receive(:timeouts=)
        allow(resolver).to receive(:getaddresses).and_raise(Resolv::ResolvError)
        allow(resolver).to receive(:close)

        expect(described_class.resolve_addresses("bad.example.com")).to eq([])
      end

      it "returns empty array on DNS timeout" do
        resolver = instance_double(Resolv::DNS)
        allow(Resolv::DNS).to receive(:new).and_return(resolver)
        allow(resolver).to receive(:timeouts=)
        allow(resolver).to receive(:getaddresses).and_raise(Resolv::ResolvTimeout)
        allow(resolver).to receive(:close)

        expect(described_class.resolve_addresses("timeout.example.com")).to eq([])
      end
    end

    context "with resolved_ips in result" do
      it "returns resolved IPs on successful validation" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).with("safe.example.com").and_return([ "93.184.216.34" ])
        result = described_class.safe_url?("http://safe.example.com")
        expect(result.safe?).to be true
        expect(result.resolved_ips).to eq([ "93.184.216.34" ])
      end
    end
  end

  describe ".safe_host?" do
    it "allows safe external hostnames" do
      result = described_class.safe_host?("example.com")
      expect(result.safe?).to be true
    end

    it "blocks localhost" do
      result = described_class.safe_host?("127.0.0.1")
      expect(result.safe?).to be false
    end

    it "blocks private IPs" do
      result = described_class.safe_host?("10.0.0.1")
      expect(result.safe?).to be false
    end

    it "blocks metadata IP" do
      result = described_class.safe_host?("169.254.169.254")
      expect(result.safe?).to be false
    end

    it "rejects blank host" do
      result = described_class.safe_host?(nil)
      expect(result.safe?).to be false
      expect(result.error).to include("Host is blank")
    end

    it "rejects empty host" do
      result = described_class.safe_host?("")
      expect(result.safe?).to be false
    end

    it "allows localhost when allow_localhost is true" do
      result = described_class.safe_host?("127.0.0.1", allow_localhost: true)
      expect(result.safe?).to be true
    end
  end
end
