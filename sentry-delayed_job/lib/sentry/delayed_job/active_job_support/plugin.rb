# frozen_string_literal: true

module Sentry
  module DelayedJob
    module ActiveJobSupport
      ACTIVE_JOB_ADAPTER = "ActiveJob::QueueAdapters::DelayedJobAdapter"
      ACTIVE_JOB_WRAPPER = "ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper"

      def self.handles?(job)
        job.payload_object.class.name == ACTIVE_JOB_WRAPPER
      rescue ::Delayed::DeserializationError
        false
      end

      module Plugin
        def record(job, *args, &block)
          return super unless Sentry.initialized? && ActiveJobSupport.handles?(job)

          capture_unreported_exception(job) { block.call(job, *args) }
        end

        private

        def capture_unreported_exception(job)
          yield
        rescue Exception => exception # rubocop:disable Lint/RescueException
          unless Sentry.exception_captured?(exception)
            Sentry.with_scope do |scope|
              apply_job_scope(scope, job)
              capture_exception(exception, job)
            end
          end
          raise
        end
      end
    end
  end
end
