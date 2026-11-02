# frozen_string_literal: true

module Sentry
  module JobExtensions
    # @api private
    class Producer < Instrumentation
      OP_NAME = "queue.publish"

      def record_span(job)
        Sentry.with_child_span(op: OP_NAME) do |span|
          safely("record the publish span") { describe_span(span, job) } if span

          yield
        end
      end

      def prepare_payload(job, payload)
        payload
      end

      def inject_trace_headers(job, payload, headers)
        extension.inject_trace_headers(job: job, payload: payload, headers: headers)
      end

      private

      def describe_span(span, job)
        span.set_description(extension.publish_description(job: job))
        span.set_origin(extension.span_origin(job: job))
        set_messaging_data(span, extension.publish_messaging_data(job: job))
        set_retry_count(span, job)
      end

      class Delegated < Producer
        def record_span(job)
          yield
        end
      end
    end
  end
end
