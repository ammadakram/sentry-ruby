# frozen_string_literal: true

require "sentry/sidekiq/retry_policy"
require "sentry/sidekiq/context_filter"

module Sentry
  module Sidekiq
    class JobExtension < Sentry::JobExtensions::Extension
      SPAN_ORIGIN = "auto.queue.sidekiq"
      SIDEKIQ_NAME = "Sidekiq"
      ENQUEUED_AT_IN_MILLISECONDS = ::Gem::Version.new(::Sidekiq::VERSION) >= ::Gem::Version.new("8.0.0")

      def initialize(name: "sidekiq", retry_policy: RetryPolicy.build)
        super(name: name)
        @retry_policy = retry_policy
      end

      def error_context_transaction_name(context)
        job = context["wrapped"] || context["class"] ? context : context[:job]
        return transaction_name(job: job) if job_class(job)

        context[:event] ? "#{SIDEKIQ_NAME}/#{context[:event]}" : SIDEKIQ_NAME
      end

      def scope_data(job:)
        return {} unless sidekiq_job?(job)

        data = {
          contexts: { sidekiq: ContextFilter.new(job).filtered },
          tags: { queue: job["queue"], jid: job["jid"] }.merge(job_tags(job))
        }
        user = job["sentry_user"]
        data[:user] = user if user.is_a?(Hash)
        data
      end

      def messaging_data(job:)
        return {} unless sidekiq_job?(job)

        {
          system: name,
          message_id: job["jid"],
          destination: job["queue"],
          receive_latency: receive_latency(job),
          body_size: body_size(job)
        }.compact
      end

      def publish_messaging_data(job:)
        return {} unless sidekiq_job?(job)

        { system: name, message_id: job["jid"], destination: job["queue"] }
      end

      def retry_info(job:)
        return super unless sidekiq_job?(job)

        { count: @retry_policy.retry_count(job) || 0, will_retry: @retry_policy.will_retry?(job) }
      end

      def inject_trace_headers(job:, payload:, headers:)
        return payload unless sidekiq_job?(payload)
        return payload if payload["trace_propagation_headers"]

        payload.merge("trace_propagation_headers" => headers)
      end

      def extract_trace_headers(job:, payload:)
        return {} unless sidekiq_job?(payload)

        payload["trace_propagation_headers"] || {}
      end

      def transaction_name(job:)
        name = job_class(job)
        name ? "#{SIDEKIQ_NAME}/#{name}" : SIDEKIQ_NAME
      end

      def publish_description(job:)
        job["class"].to_s
      end

      def span_origin(job:)
        SPAN_ORIGIN
      end

      def integration(job:)
        Sentry::Sidekiq
      end

      def producer(job:)
        @producer ||= Sentry::JobExtensions::Producer::Delegated.new(extension: self)
      end

      private

      def sidekiq_job?(job)
        job.is_a?(Hash) && job.key?("jid")
      end

      def job_class(job)
        job["wrapped"] || job["class"] if job.is_a?(Hash)
      end

      def job_tags(job)
        Array(job["tags"]).each_with_object({}) { |name, tags_hash| tags_hash[:"sidekiq.#{name}"] = true }
      end

      def body_size(job)
        ::Sidekiq.dump_json(job).bytesize
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
