# frozen_string_literal: true

require "sentry/rails/active_job_extension"
require "sentry/delayed_job/active_job_support/plugin"

module Sentry
  module DelayedJob
    class ActiveJobExtension < Sentry::Rails::ActiveJobExtension
      def initialize(name: "delayed_job", integration: Sentry::DelayedJob, origin: Plugin::SPAN_ORIGIN, **dependencies)
        super(name: name, integration: integration, origin: origin, **dependencies)
      end

      def scope_data(job:, **)
        context = (job._sentry_job_data || {}).reject { |key, _value| key == Sentry::Rails::ActiveJobExtensions::SENTRY_PAYLOAD_KEY }
        context = context.reject { |key, _value| key == "arguments" } unless Sentry.configuration.data_collection.queues

        tags = { "delayed_job.queue" => job.queue_name }
        tags["delayed_job.id"] = job.provider_job_id.to_s if job.provider_job_id

        { contexts: { Plugin::ACTIVE_JOB_CONTEXT_KEY => context.transform_keys(&:to_sym) }, tags: tags }
      end
    end

    Sentry::Rails.register_active_job_extension(:delayed_job, ActiveJobExtension.new)
  end
end
