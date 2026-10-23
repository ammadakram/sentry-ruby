# frozen_string_literal: true

module Sentry
  module JobExtensions
    # @api private
    class Consumer < Instrumentation
      OP_NAME = "queue.process"

      def apply_scope_data(scope, job)
        data = registry.for(job).scope_data(job: job)
        scope.set_contexts(data[:contexts]) if data[:contexts]
        scope.set_tags(data[:tags]) if data[:tags]
        scope.set_extras(data[:extra]) if data[:extra]
        scope.set_user(data[:user]) if data[:user]
      end

      def start_transaction(scope, job, trace_headers: {})
        extension = registry.for(job)
        options = {
          name: scope.transaction_name,
          source: scope.transaction_source,
          op: OP_NAME,
          origin: extension.span_origin(job: job)
        }

        transaction = if trace_headers.empty?
          Sentry.start_transaction(**options)
        else
          Sentry.start_transaction(transaction: Sentry.continue_trace(trace_headers, **options), **options)
        end
        return unless transaction

        scope.set_span(transaction)
        safely(extension, "record the messaging data") do
          set_messaging_data(transaction, extension.messaging_data(job: job))
          set_retry_count(transaction, extension, job)
        end

        transaction
      end

      def finish_transaction(transaction, status)
        return if !transaction || transaction.timestamp

        transaction.set_http_status(status)
        transaction.finish
      end

      def report_exception?(job, exception)
        registry.for(job).report_exception?(job: job, exception: exception)
      end

      def report_retried_exception?(job, exception)
        registry.for(job).report_retried_exception?(job: job, exception: exception)
      end

      def capture_exception(job, exception, contexts: {}, tags: {}, extra: {})
        extension = registry.for(job)
        error_data = additive_error_data(extension.error_data(job: job, exception: exception))

        options = {
          extra: error_data[:extra].merge(matching_keys(extra, error_data[:extra])),
          tags: error_data[:tags].merge(matching_keys(tags, error_data[:tags])),
          hint: { background: false }
        }
        contexts = error_data[:contexts].merge(matching_keys(contexts, error_data[:contexts]))
        options[:contexts] = contexts unless contexts.empty?

        extension.integration(job: job).capture_exception(exception, **options)
      end

      private

      def additive_error_data(data)
        scope = Sentry.get_current_scope

        {
          contexts: matching_keys(data.fetch(:contexts, {}), scope.contexts).to_h do |name, context|
            scope_context = scope.contexts.fetch(name, {})
            context = matching_keys(context, scope_context)
            [name, context.merge(scope_context)]
          end,
          tags: matching_keys(data.fetch(:tags, {}), scope.tags).reject { |key, _value| scope.tags.key?(key) },
          extra: matching_keys(data.fetch(:extra, {}), scope.extra).reject { |key, _value| scope.extra.key?(key) }
        }
      end

      def matching_keys(data, reference)
        keys = reference.keys.to_h { |key| [key.to_s, key] }
        data.transform_keys { |key| keys.fetch(key.to_s, key) }
      end
    end
  end
end
