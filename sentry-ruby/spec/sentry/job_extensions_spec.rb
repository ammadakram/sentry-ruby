# frozen_string_literal: true

RSpec.describe "Sentry job extensions" do
  describe "Sentry::JobExtensions::Extension" do
    it "rejects a blank name" do
      expect { Sentry::JobExtensions::Extension.new(name: "") }.to raise_error(ArgumentError)
      expect { Sentry::JobExtensions::Extension.new(name: nil) }.to raise_error(ArgumentError)
    end
  end

  describe "Sentry::JobExtensions::Extension hooks" do
    let(:extension) { Sentry::JobExtensions::Extension.new(name: "noop") }
    let(:job) { double("job") }
    let(:exception) { RuntimeError.new("job failed") }
    let(:payload) { { "class" => "HardJob", "args" => [1] } }

    def retrying_extension(will_retry:)
      Class.new(Sentry::JobExtensions::Extension) do
        define_method(:retry_info) { |job:| { count: 1, will_retry: will_retry } }
      end.new(name: "retrying")
    end

    it "supplies no scope, error or messaging data by default" do
      expect(extension.scope_data(job: job)).to eq({})
      expect(extension.error_data(job: job, exception: exception)).to eq({})
      expect(extension.messaging_data(job: job)).to eq({})
      expect(extension.publish_messaging_data(job: job)).to eq({})
    end

    it "reports no retries and no pending retry by default" do
      expect(extension.retry_info(job: job)).to eq(count: 0, will_retry: false)
    end

    it "carries no trace headers and leaves the payload unchanged by default" do
      expect(extension.extract_trace_headers(job: job, payload: payload)).to eq({})
      expect(extension.inject_trace_headers(job: job, payload: payload, headers: { "sentry-trace" => "trace" })).to equal(payload)
    end

    it "reports an exception only when the backend will not retry the job" do
      expect(retrying_extension(will_retry: false).report_exception?(job: job, exception: exception)).to be(true)
      expect(retrying_extension(will_retry: true).report_exception?(job: job, exception: exception)).to be(false)
    end

    it "does not report exceptions the job integration retries by default" do
      expect(extension.report_retried_exception?(job: job, exception: exception)).to be(false)
    end

    it "uses the messaging data for the publish span unless overridden" do
      messaging = Class.new(Sentry::JobExtensions::Extension) do
        def messaging_data(job:)
          { system: "backend" }
        end
      end.new(name: "messaging")

      expect(messaging.publish_messaging_data(job: job)).to eq(system: "backend")
    end
  end
end
