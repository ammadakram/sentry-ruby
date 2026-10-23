# frozen_string_literal: true

require "sentry/rails/active_job_extension"
require "sentry/rails/active_job/producer"

module Sentry
  module Sidekiq
    class ActiveJobExtension < Sentry::Rails::ActiveJobExtension
      class Producer < Sentry::Rails::ActiveJobExtension::Producer
        def record_span(job)
          yield
        end
      end

      def initialize
        super(name: "sidekiq_active_job")
      end

      def handles?(job)
        super && job.class.queue_adapter.class.name == ActiveJobSupport::ACTIVE_JOB_ADAPTER
      end

      def transaction_name(job:)
        "#{JobExtension::SIDEKIQ_NAME}/#{super}"
      end

      def span_origin(job:)
        JobExtension::SPAN_ORIGIN
      end

      def integration(job:)
        Sentry::Sidekiq
      end

      def report_retried_exception?(job:, exception:)
        false
      end

      def producer(job:)
        @producer ||= Producer.new(registry: registry)
      end
    end

    Sentry.register_job_extension(ActiveJobExtension.new)
  end
end
