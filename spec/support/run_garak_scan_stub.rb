RSpec.configure do |config|
  config.before(:each) do
    allow_any_instance_of(RunGarakScan).to receive(:call) do |instance|
      instance.report.update(status: :starting)
    end
  end
end
