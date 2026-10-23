# frozen_string_literal: true

module Sentry
  module JobExtensions
    # @api private
    class Instrumentation
      include LoggingHelper

      MESSAGING_DATA_ATTRIBUTES = {
        system: Span::DataConventions::MESSAGING_SYSTEM,
        message_id: Span::DataConventions::MESSAGING_MESSAGE_ID,
        destination: Span::DataConventions::MESSAGING_DESTINATION_NAME,
        receive_latency: Span::DataConventions::MESSAGING_MESSAGE_RECEIVE_LATENCY
      }.freeze

      attr_reader :registry

      def initialize(registry: Sentry.job_extensions)
        @registry = registry
      end

      private

      def safely(extension, context, fallback: nil)
        yield
      rescue StandardError => e
        log_error("Job extension #{extension.name.inspect} failed to #{context}", e)
        fallback
      end

      def set_messaging_data(span, data)
        data.slice(*MESSAGING_DATA_ATTRIBUTES.keys).each do |key, value|
          span.set_data(MESSAGING_DATA_ATTRIBUTES[key], value)
        end
      end

      def set_retry_count(span, extension, job)
        span.set_data(Span::DataConventions::MESSAGING_MESSAGE_RETRY_COUNT, extension.retry_info(job: job)[:count])
      end

      def sdk_logger
        Sentry.sdk_logger if Sentry.initialized?
      end
    end
  end
end
