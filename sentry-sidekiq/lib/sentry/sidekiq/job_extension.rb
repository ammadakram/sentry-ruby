# frozen_string_literal: true

require "sentry/sidekiq/retry_policy"
require "sentry/sidekiq/failure_reporting"
require "sentry/sidekiq/context_filter"

module Sentry
  module Sidekiq
    class JobExtension < Sentry::JobExtensions::Extension
      SPAN_ORIGIN = "auto.queue.sidekiq"
      SIDEKIQ_NAME = "Sidekiq"
      ENQUEUED_AT_IN_MILLISECONDS = ::Gem::Version.new(::Sidekiq::VERSION) >= ::Gem::Version.new("8.0.0")

      def initialize(
        name: "sidekiq",
        integration: Sentry::Sidekiq,
        origin: SPAN_ORIGIN,
        retry_policy: RetryPolicy.build,
        failure_reporting: FailureReporting.new(retry_policy: retry_policy),
        serializer: ::Sidekiq
      )
        super(name: name, integration: integration, origin: origin)
        @retry_policy = retry_policy
        @failure_reporting = failure_reporting
        @serializer = serializer
      end

      def error_context(context)
        ContextFilter.new(context).filtered
      end

      def scope_data(job:, **)
        data = {
          contexts: { sidekiq: job },
          tags: { queue: job["queue"], jid: job["jid"] }.merge(job_tags(job))
        }
        user = job["sentry_user"]
        data[:user] = user if user.is_a?(Hash)
        data
      end

      def messaging_data(job:, **)
        {
          system: name,
          message_id: job["jid"],
          destination: job["queue"],
          receive_latency: receive_latency(job),
          retry_count: @retry_policy.retry_count(job) || 0,
          body_size: body_size(job)
        }.compact
      end

      def publish_messaging_data(job:, **)
        { system: name, message_id: job["jid"], destination: job["queue"] }
      end

      def will_retry?(job:, **)
        @retry_policy.will_retry?(job)
      end

      def report_exception?(job:, exception:, sidekiq_config: nil, **)
        @failure_reporting.report?(job, sidekiq_config)
      end

      def inject_trace_headers(job:, payload:, headers:, **)
        return payload if payload["trace_propagation_headers"]

        payload.merge("trace_propagation_headers" => headers)
      end

      def extract_trace_headers(job:, **)
        job["trace_propagation_headers"] || {}
      end

      def transaction_name(job:, **)
        name = job_class(job)
        name ? "#{SIDEKIQ_NAME}/#{name}" : SIDEKIQ_NAME
      end

      def publish_description(job:, **)
        job["class"].to_s
      end

      def publish_span_origin(job:, **)
        Span::DEFAULT_SPAN_ORIGIN
      end

      private

      def job_class(job)
        job["class"] if job.is_a?(Hash)
      end

      def job_tags(job)
        Array(job["tags"]).each_with_object({}) { |name, tags_hash| tags_hash[:"sidekiq.#{name}"] = true }
      end

      def body_size(job)
        @serializer.dump_json(job).bytesize
      rescue StandardError
        nil
      end

      def enqueued_at(job)
        enqueued_at = job["enqueued_at"]
        return unless enqueued_at

        ENQUEUED_AT_IN_MILLISECONDS ? Time.at(Rational(enqueued_at, 1000)) : Time.at(enqueued_at)
      end

      def receive_latency(job)
        Sentry::Utils::Latency.milliseconds_since(enqueued_at(job))&.round
      end
    end
  end
end
