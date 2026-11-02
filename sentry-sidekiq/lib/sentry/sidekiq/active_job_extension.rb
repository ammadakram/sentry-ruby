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
        @producer ||= Producer.new(extension: self)
      end
    end

    Sentry::Rails.register_active_job_extension(:sidekiq, ActiveJobExtension.new)
  end
end
