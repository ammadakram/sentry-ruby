# frozen_string_literal: true

require "sentry/sidekiq/job_extension"
require "sentry/sidekiq/consumer"
require "sentry/sidekiq/producer"

module Sentry
  module Sidekiq
    class SentryContextServerMiddleware
      SPAN_ORIGIN = JobExtension::SPAN_ORIGIN

      def self.consumer
        @consumer ||= Consumer.new(registry: Sentry::Sidekiq.job_extensions)
      end

      def call(worker, job, queue)
        return yield unless Sentry.initialized?

        sidekiq_job = job.merge("queue" => queue)
        extension = consumer.registry.for(sidekiq_job)

        Sentry.clone_hub_to_current_thread
        scope = Sentry.get_current_scope
        safely(extension, "apply scope data") { consumer.apply_scope_data(scope, sidekiq_job) }
        name = safely(extension, "name the transaction", fallback: job_extension.transaction_name(job: sidekiq_job)) do
          extension.transaction_name(job: sidekiq_job)
        end
        scope.set_transaction_name(name, source: :task)
        trace_headers = safely(extension, "extract trace headers", fallback: {}) do
          extension.extract_trace_headers(job: sidekiq_job, payload: sidekiq_job)
        end
        scope.generate_propagation_context if trace_headers.empty?
        transaction = safely(extension, "start the transaction") do
          consumer.start_transaction(scope, sidekiq_job, trace_headers: trace_headers)
        end

        begin
          yield
        rescue
          consumer.finish_transaction(transaction, 500)
          raise
        end

        consumer.finish_transaction(transaction, 200)
        # don't need to use ensure here
        # if the job failed, we need to keep the scope for error handler. and the scope will be cleared there
        scope.clear
      end

      private

      def consumer
        self.class.consumer
      end

      def safely(extension, context, fallback: nil, &block)
        consumer.safely(extension, context, fallback: fallback, &block)
      end

      def job_extension
        Sentry::Sidekiq.job_extension
      end
    end

    class SentryContextClientMiddleware
      def self.producer
        @producer ||= Producer.new(registry: Sentry::Sidekiq.job_extensions)
      end

      def call(worker_class, job, queue, _redis_pool)
        return yield unless Sentry.initialized?

        if Sentry.configuration.data_collection.user_info
          user = Sentry.get_current_scope.user
          job["sentry_user"] = user unless user.empty?
        end

        if Sentry.configuration.sidekiq.propagate_traces
          headers = Sentry.get_trace_propagation_headers
          extension = producer.registry.for(job)
          job.replace(producer.safely(extension, "inject trace headers", fallback: job) { producer.inject_trace_headers(job, job, headers) })
        end

        producer.record_span(job.merge("queue" => queue)) { yield }
      end

      private

      def producer
        self.class.producer
      end
    end
  end
end
