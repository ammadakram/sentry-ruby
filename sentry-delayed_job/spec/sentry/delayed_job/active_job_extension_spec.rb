# frozen_string_literal: true

require "spec_helper"
require "rails"

return if Rails.version.to_f < 7.2

require "active_job"
require "sentry-rails"
require "sentry/rails/active_job"
require "sentry/delayed_job/active_job_extension"

RSpec.describe Sentry::DelayedJob::ActiveJobExtension do
  class DelayedJobExtensionJob < ActiveJob::Base
    self.queue_adapter = :delayed_job

    def perform(message); end
  end

  class InlineDelayedJobExtensionJob < ActiveJob::Base
    self.queue_adapter = :inline

    def perform; end
  end

  subject(:extension) { described_class.new }

  let(:job_data) do
    DelayedJobExtensionJob.new("hello").serialize.merge(
      "queue_name" => "events",
      "provider_job_id" => 42,
      "_sentry" => { "trace_propagation_headers" => { "sentry-trace" => "trace" } }
    )
  end

  let(:job) { ActiveJob::Base.deserialize(job_data) }

  before do
    ActiveJob::Base.logger = nil
    ActiveJob::Base.send(:prepend, Sentry::Rails::ActiveJobExtensions)
    perform_basic_setup
  end

  it "should be the extension for ActiveJob jobs on the delayed_job adapter" do
    expect(Sentry::Rails.active_job_extension_for(DelayedJobExtensionJob)).to be_a(described_class)
  end

  it "should not be the extension for ActiveJob jobs on another adapter" do
    expect(Sentry::Rails.active_job_extension_for(InlineDelayedJobExtensionJob)).not_to be_a(described_class)
  end

  it "should give the consumer the delayed_job origin" do
    expect(extension.span_origin(job: job)).to eq("auto.queue.delayed_job")
  end

  it "should capture exceptions under the delayed_job integration" do
    expect(extension.integration(job: job)).to eq(Sentry::DelayedJob)
  end

  describe "#scope_data" do
    it "should tag the delayed_job queue and record and add the Active-Job context" do
      Sentry.configuration.data_collection.queues = true

      data = extension.scope_data(job: job)

      expect(data[:tags]).to eq("delayed_job.queue" => "events", "delayed_job.id" => "42")
      expect(data[:contexts][:"Active-Job"]).to include(
        job_class: "DelayedJobExtensionJob",
        job_id: job.job_id,
        queue_name: "events",
        arguments: ["hello"]
      )
      expect(data[:contexts][:"Active-Job"]).not_to have_key(:_sentry)
    end

    it "should leave the job arguments out of the Active-Job context when queue data collection is off" do
      Sentry.configuration.data_collection.queues = false

      context = extension.scope_data(job: job)[:contexts][:"Active-Job"]

      expect(context).not_to have_key(:arguments)
      expect(context).to include(job_id: job.job_id, queue_name: "events")
    end
  end

  describe "#messaging_data" do
    it "should describe the delayed_job message" do
      expect(extension.messaging_data(job: job)).to include(
        system: "delayed_job",
        message_id: job.job_id,
        destination: "events"
      )
    end
  end
end
