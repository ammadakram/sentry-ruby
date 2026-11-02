# frozen_string_literal: true

module Sentry
  module Rails
    class ActiveJobExtension < Sentry::JobExtensions::Extension
      SPAN_ORIGIN = "auto.queue.active_job"
      USER_FIELDS_ALLOWLIST = %w[id email username].freeze

      def initialize(name: "active_job")
        super(name: name)
      end

      def self.adapter_name(job_class)
        name = job_class.queue_adapter_name if job_class.respond_to?(:queue_adapter_name)
        (name || job_class.queue_adapter.class.name.demodulize.delete_suffix("Adapter").underscore).to_sym
      end

      def consumer
        @consumer ||= Consumer.new(extension: self)
      end

      def producer(job:)
        @producer ||= Producer.new(extension: self)
      end

      def extract_trace_headers(job:, payload:)
        job._sentry&.[]("trace_propagation_headers") || {}
      end

      def messaging_data(job:)
        data = publish_messaging_data(job: job)
        data[:receive_latency] = Sentry::Utils::Latency.milliseconds_since(job.enqueued_at) if job.respond_to?(:enqueued_at)
        data[:body_size] = body_size(job._sentry_job_data) if Sentry.get_current_scope.get_span&.sampled
        data.compact
      end

      def body_size(payload)
        JSON.generate(payload).bytesize if payload
      rescue StandardError
        nil
      end

      def publish_messaging_data(job:)
        name = job.class.queue_adapter_name if job.class.respond_to?(:queue_adapter_name)
        {
          system: name.to_s.empty? ? "activejob" : name.to_s,
          message_id: job.job_id,
          destination: job.queue_name
        }
      end

      def retry_info(job:)
        { count: job.executions.to_i, will_retry: false }
      end

      def report_retried_exception?(job:, exception:)
        Sentry.configuration.rails.active_job_report_on_retry_error
      end

      def transaction_name(job:)
        job.class.name
      end

      def publish_description(job:)
        job.class.name
      end

      def span_origin(job:)
        SPAN_ORIGIN
      end

      def integration(job:)
        Sentry::Rails
      end
    end
  end
end
