# frozen_string_literal: true

require "sentry/rails/active_job_extension"
require "sentry/resque/active_job_support"

module Sentry
  module Resque
    class ActiveJobExtension < Sentry::Rails::ActiveJobExtension
      SPAN_ORIGIN = "auto.queue.resque"

      def initialize
        super(name: "resque")
      end

      def handles?(job)
        super && job.class.queue_adapter.class.name == ActiveJobSupport::ACTIVE_JOB_ADAPTER
      end

      def scope_data(job:)
        job_data = job._sentry_job_data || {}
        context = {
          job_class: job.class.name,
          job_id: job.job_id,
          executions: job_data["executions"],
          exception_executions: job_data["exception_executions"],
          locale: job_data["locale"],
          enqueued_at: job_data["enqueued_at"],
          queue: job.queue_name
        }
        context[:arguments] = job_data["arguments"] if Sentry.configuration.data_collection.queues

        { contexts: { "Active-Job": context }, tags: { "resque.queue" => job.queue_name } }
      end

      def messaging_data(job:)
        job_data = job._sentry_job_data
        {
          system: name,
          message_id: job.job_id,
          destination: job.queue_name,
          body_size: body_size(job_data),
          receive_latency: Sentry::Utils::Latency.milliseconds_since(job_data&.[]("enqueued_at"))
        }.compact
      end

      def span_origin(job:)
        SPAN_ORIGIN
      end

      def integration(job:)
        Sentry::Resque
      end

      def report_retried_exception?(job:, exception:)
        false
      end

      private

      def body_size(job_data)
        ::Resque.encode("class" => ActiveJobSupport::ACTIVE_JOB_WRAPPER, "args" => [job_data]).bytesize if job_data
      rescue StandardError
        nil
      end
    end

    Sentry.register_job_extension(ActiveJobExtension.new)
  end
end
