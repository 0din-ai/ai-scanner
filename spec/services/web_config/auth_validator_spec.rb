require "rails_helper"

RSpec.describe WebConfig::AuthValidator do
  def errors_for(auth)
    described_class.new(auth).errors
  end

  it "accepts a full valid auth block" do
    auth = {
      "cookies" => [ { "name" => "s", "value" => "v", "domain" => "example.com", "path" => "/", "secure" => true, "httpOnly" => true, "sameSite" => "Lax" } ],
      "headers" => { "Authorization" => "Bearer x" },
      "storage_state" => { "cookies" => [], "origins" => [] }
    }
    expect(errors_for(auth)).to be_empty
  end

  it "accepts an empty object" do
    expect(errors_for({})).to be_empty
  end

  it "rejects a non-object auth" do
    expect(errors_for("nope")).to include("auth must be an object")
  end

  it "rejects unsupported top-level keys" do
    expect(errors_for({ "token" => "x" })).to include(a_string_matching(/unsupported key/))
  end

  it "rejects a cookie missing name" do
    expect(errors_for({ "cookies" => [ { "value" => "v", "domain" => "e.com" } ] }))
      .to include("auth.cookies[0].name is required")
  end

  it "rejects a cookie missing value" do
    expect(errors_for({ "cookies" => [ { "name" => "s", "domain" => "e.com" } ] }))
      .to include("auth.cookies[0].value is required")
  end

  it "rejects a cookie with neither url nor domain" do
    expect(errors_for({ "cookies" => [ { "name" => "s", "value" => "v" } ] }))
      .to include("auth.cookies[0] must include either 'url' or 'domain'")
  end

  it "rejects a bad sameSite value" do
    expect(errors_for({ "cookies" => [ { "name" => "s", "value" => "v", "domain" => "e.com", "sameSite" => "Whenever" } ] }))
      .to include("auth.cookies[0].sameSite must be one of Strict, Lax, None")
  end

  it "rejects a non-boolean secure flag" do
    expect(errors_for({ "cookies" => [ { "name" => "s", "value" => "v", "domain" => "e.com", "secure" => "yes" } ] }))
      .to include("auth.cookies[0].secure must be true or false")
  end

  it "rejects more than 50 cookies" do
    cookies = Array.new(51) { { "name" => "s", "value" => "v", "domain" => "e.com" } }
    expect(errors_for({ "cookies" => cookies })).to include("auth.cookies cannot have more than 50 entries")
  end

  it "rejects non-string header values" do
    expect(errors_for({ "headers" => { "X-Count" => 5 } }))
      .to include("auth.headers['X-Count'] must be a string")
  end

  it "rejects a non-object storage_state" do
    expect(errors_for({ "storage_state" => "blob" }))
      .to include("auth.storage_state must be an object")
  end
end
