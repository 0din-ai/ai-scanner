require "rails_helper"

# Guards the SSRF hardening: the Target RestGenerator uri and the OutputServer host /
# endpoint_path must be screened by UrlSafetyValidator before any request is made.
RSpec.describe "SSRF hardening" do
  let(:company) { create(:company) }

  describe Target do
    def api_target(uri)
      build(:target, company: company, json_config: { rest: { RestGenerator: { uri: uri } } }.to_json)
    end

    it "rejects a RestGenerator uri that resolves to internal/metadata addresses" do
      ActsAsTenant.with_tenant(company) do
        # 169.254 (cloud metadata) + RFC1918 are blocked regardless of env. Loopback is
        # intentionally allowed in dev/test (allow_localhost?), so it's not asserted here.
        %w[http://169.254.169.254/latest/meta-data/ http://10.1.2.3/ http://172.16.5.5/].each do |uri|
          t = api_target(uri)
          expect(t.valid?).to be(false), "expected #{uri} to be rejected"
          expect(t.errors[:json_config].join).to match(/not allowed/i)
        end
      end
    end

    it "allows a RestGenerator uri pointing at a public address" do
      ActsAsTenant.with_tenant(company) do
        t = api_target("http://8.8.8.8/v1/chat")
        t.valid?
        expect(t.errors[:json_config]).to be_empty
      end
    end

    it "rejects a RestGenerator host containing an env-var placeholder (substituted to internal at scan time)" do
      ActsAsTenant.with_tenant(company) do
        [ "http://$SSRF_HOST/latest", "http://$X.example.com/v1" ].each do |uri|
          t = api_target(uri)
          expect(t.valid?).to be(false), "expected #{uri} rejected"
          expect(t.errors[:json_config].join).to match(/placeholder/i)
        end
      end
    end

    it "rejects a non-string RestGenerator uri (crafted-JSON type confusion)" do
      ActsAsTenant.with_tenant(company) do
        t = build(:target, company: company, json_config: { rest: { RestGenerator: { uri: { evil: 1 } } } }.to_json)
        expect(t.valid?).to be(false)
        expect(t.errors[:json_config].join).to match(/must be a string/i)
      end
    end

    it "Target#rest_uri_safe? re-validates the RestGenerator uri at launch time" do
      ActsAsTenant.with_tenant(company) do
        internal = api_target("http://169.254.169.254/")
        expect(internal.rest_uri_safe?).to be(false)

        public_t = api_target("http://8.8.8.8/v1")
        expect(public_t.rest_uri_safe?).to be(true)

        # non-REST target (no uri to fetch) is considered safe
        expect(build(:target, company: company).rest_uri_safe?).to be(true)
      end
    end
  end

  describe OutputServer do
    it "rejects an internal host" do
      ActsAsTenant.with_tenant(company) do
        os = build(:output_server, company: company, host: "169.254.169.254")
        os.valid?
        expect(os.errors[:host].join).to match(/not allowed/i)
      end
    end

    it "allows a public host" do
      ActsAsTenant.with_tenant(company) do
        os = build(:output_server, company: company, host: "8.8.8.8")
        os.valid?
        expect(os.errors[:host]).to be_empty
      end
    end

    it "rejects hosts containing URI delimiters (userinfo/path injection bypass)" do
      ActsAsTenant.with_tenant(company) do
        [ "example.com@169.254.169.254", "169.254.169.254#x", "host/path", "a b", "$SSRF_HOST" ].each do |h|
          os = build(:output_server, company: company, host: h)
          os.valid?
          expect(os.errors[:host].join).to match(/invalid characters/i), "expected #{h} to be rejected"
        end
      end
    end

    it "rejects an endpoint_path that injects a host via userinfo (@) and allows a plain path" do
      ActsAsTenant.with_tenant(company) do
        bad = build(:output_server, company: company, host: "8.8.8.8", endpoint_path: "@169.254.169.254/latest")
        bad.valid?
        expect(bad.errors[:endpoint_path].join).to match(/plain path/i)

        good = build(:output_server, company: company, host: "8.8.8.8", endpoint_path: "/services/collector")
        good.valid?
        expect(good.errors[:endpoint_path]).to be_empty
      end
    end

    describe "#destination_safe? (send-time DNS-rebinding recheck)" do
      it "re-resolves and blocks internal hosts, allows public hosts" do
        ActsAsTenant.with_tenant(company) do
          expect(build(:output_server, company: company, host: "169.254.169.254").destination_safe?).to be(false)
          expect(build(:output_server, company: company, host: "8.8.8.8").destination_safe?).to be(true)
        end
      end

      it "validates the EFFECTIVE host (stale endpoint_path userinfo injection)" do
        ActsAsTenant.with_tenant(company) do
          # build() skips validation, simulating a row saved before endpoint_path was checked.
          os = build(:output_server, company: company, host: "8.8.8.8", port: 443, endpoint_path: "@169.254.169.254/latest")
          expect(os.destination_safe?).to be(false)
        end
      end
    end
  end
end
