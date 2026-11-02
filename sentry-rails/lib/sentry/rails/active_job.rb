# frozen_string_literal: true

require "set"
require "sentry/rails/serializer"
require "sentry/rails/error_reporter_context"
require "sentry/rails/active_job_extension"
require "sentry/rails/active_job/producer"
require "sentry/rails/active_job/consumer"

module Sentry
  module Rails
    module ActiveJobExtensions
      SENTRY_PAYLOAD_KEY = "_sentry"

      def self.prepended(base)
        base.attr_accessor :_sentry
        base.attr_reader :_sentry_job_data
      end

      def perform_now
        if !Sentry.initialized? || already_supported_by_sentry_integration?
          super
        else
          SentryReporter.record(self, user: _sentry&.[]("user"), payload: _sentry_job_data) { super }
        end
      end

      def serialize
        payload = super
        return payload if !Sentry.initialized? || already_supported_by_sentry_integration?
        SentryReporter.prepare_payload(self, payload)
      end

      def deserialize(job_data)
        super
        return if !Sentry.initialized? || already_supported_by_sentry_integration?

        begin
          @_sentry_job_data = job_data
          self._sentry = job_data[SENTRY_PAYLOAD_KEY]
        rescue StandardError => e
          Sentry.sdk_logger&.error("sentry-rails: failed to extract _sentry payload: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}")
        end
      end

      def already_supported_by_sentry_integration?
        !Sentry::Rails.active_job_owns_adapter?(self.class.queue_adapter.class)
      end

      class SentryReporter
        EVENT_HANDLERS = {
          "enqueue_retry.active_job" => :retry_handler
        }

        class << self
          include ErrorReporterContext

          def default_extension
            @default_extension ||= ActiveJobExtension.new
          end

          def consumer(job)
            extension_for(job).consumer
          end

          def producer(job)
            extension_for(job).producer(job: job)
          end

          def prepare_payload(job, payload)
            safely(job, "inject _sentry payload", fallback: payload) { producer(job).prepare_payload(job, payload) }
          end

          def extension_for(job)
            Sentry::Rails.active_job_extensions.fetch(ActiveJobExtension.adapter_name(job.class), default_extension)
          end

          def producer_callback_registered?
            @producer_callback_registered ||= false
          end

          def producer_callback_registered!
            @producer_callback_registered = true
          end

          def record_producer_span(job, &enqueue)
            return yield if !Sentry.initialized? || job.already_supported_by_sentry_integration?

            enqueued = false
            run_enqueue = lambda do
              enqueued = true
              enqueue.call
            end

            begin
              job_producer = safely(job, "build the producer", fallback: default_extension.producer(job: job)) { producer(job) }
              job_producer.record_span(job, &run_enqueue)
            rescue StandardError => e
              raise if enqueued

              Sentry.sdk_logger&.error("sentry-rails: failed to record producer span: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}")
              run_enqueue.call
            end
          end

          def record(job, user: nil, payload: nil, &block)
            with_isolated_scope do |scope|
              record_in_scope(scope, job, user: user, payload: payload, &block)
            end
          end

          def record_in_scope(scope, job, user: nil, payload: nil)
            transaction = nil
            job_consumer = consumer(job)
            extension = job_consumer.extension

            begin
              scope.set_user(user.transform_keys(&:to_sym)) if user && !user.empty?

              safely(job, "apply scope data") { job_consumer.apply_scope_data(scope, job) }
              apply_active_job_context(scope, job)

              name = safely(job, "name the transaction", fallback: job.class.name) { extension.transaction_name(job: job) }
              scope.set_transaction_name(name, source: :task)

              transaction = safely(job, "start the transaction") do
                trace_headers = extension.extract_trace_headers(job: job, payload: payload)
                job_consumer.start_transaction(scope, job, trace_headers: trace_headers)
              end

              yield.tap do
                job_consumer.finish_transaction(transaction, 200)
              end
            rescue Exception => e # rubocop:disable Lint/RescueException
              job_consumer.finish_transaction(transaction, 500)

              if safely(job, "decide whether to report the job exception", fallback: true) { job_consumer.report_exception?(job, e) }
                capture_exception(job, e)
              end

              raise
            end
          end

          def capture_exception(job, e)
            error_data = active_job_error_data(job)
            captured = safely(job, "capture the job exception", fallback: false) do
              consumer(job).capture_exception(job, e, **error_data)
              true
            end
            return if captured

            error_data.delete(:contexts) if error_data[:contexts].empty?
            Sentry::Rails.capture_exception(e, **error_data, hint: { background: false })
          end

          def register_event_handlers
            EVENT_HANDLERS.each do |name, handler|
              subscribers << ActiveSupport::Notifications.subscribe(name) do |*args|
                public_send(handler, *args)
              end
            end
          end

          def detach_event_handlers
            subscribers.each do |subscriber|
              ActiveSupport::Notifications.unsubscribe(subscriber)
            end
            subscribers.clear
          end

          # This handler does not capture error unless `active_job_report_on_retry_error` is true
          def retry_handler(*args)
            handle_error_event(*args) do |job, error|
              return if error.nil?
              return if !Sentry.initialized? || job.already_supported_by_sentry_integration?
              report = safely(job, "decide whether to report the retried exception", fallback: Sentry.configuration.rails.active_job_report_on_retry_error) do
                consumer(job).report_retried_exception?(job, error)
              end
              return unless report

              capture_exception(job, error)
            end
          end

          def handle_error_event(*args)
            event = ActiveSupport::Notifications::Event.new(*args)
            yield(event.payload[:job], event.payload[:error])
          end

          private :record_in_scope

          private

          def safely(job, context, fallback: nil, &block)
            consumer(job).safely(context, fallback: fallback, &block)
          end

          def active_job_error_data(job)
            queues = Sentry.configuration.data_collection.queues
            extra = {
              active_job: job.class.name,
              scheduled_at: job.scheduled_at,
              job_id: job.job_id,
              provider_job_id: job.provider_job_id,
              locale: job.locale
            }
            arguments = serialize_arguments(job.arguments) if queues
            extra[:arguments] = arguments unless arguments.nil?

            {
              contexts: queues ? execution_context : {},
              tags: { job_id: job.job_id, provider_job_id: job.provider_job_id },
              extra: extra
            }
          end

          def serialize_arguments(arguments)
            terms = ::Rails.application.config.filter_parameters.select do |term|
              term.is_a?(String) || term.is_a?(Symbol) || term.is_a?(Regexp)
            end
            collection = Sentry::DataCollection::KeyValueCollection.new(mode: :deny_list, terms: terms)
            Sentry::Rails::Serializer.serialize(arguments, collection)
          rescue StandardError => e
            Sentry.sdk_logger&.error("sentry-rails: failed to serialize job arguments: #{e.class}: #{e.message}")
            nil
          end

          def apply_active_job_context(scope, job)
            required = {
              job_class: job.class.name,
              job_id: job.job_id,
              queue: job.queue_name,
              provider_job_id: job.provider_job_id
            }
            context = (scope.contexts.delete("active_job") || {}).merge(scope.contexts.delete(:active_job) || {})
            keys = required.keys.to_h { |key| [key.to_s, key] }
            context = context.transform_keys { |key| keys.fetch(key.to_s, key) }
            scope.set_context(:active_job, context.merge(required))
            scope.tags.delete("queue")
            scope.set_tag(:queue, job.queue_name)
          end

          def with_isolated_scope(&block)
            original_hub = Sentry.get_current_hub_internal
            Sentry.clone_hub_to_current_thread
            Sentry.with_scope(&block)
          ensure
            Sentry.set_current_hub_internal(original_hub)
          end

          def subscribers
            @__subscribers__ ||= Set.new
          end
        end
      end
    end
  end
end
