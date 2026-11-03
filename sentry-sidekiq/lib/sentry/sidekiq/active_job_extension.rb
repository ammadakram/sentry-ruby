# frozen_string_literal: true

require "sentry/rails/active_job_extension"

module Sentry
  module Sidekiq
    class ActiveJobExtension < Sentry::Rails::ActiveJobExtension
      def initialize(name: "sidekiq_active_job", integration: Sentry::Sidekiq, origin: JobExtension::SPAN_ORIGIN, **dependencies)
        super(name: name, integration: integration, origin: origin, **dependencies)
      end

      def record_publish_span?(job:, **)
        false
      end

      def transaction_name(job:, **)
        "#{JobExtension::SIDEKIQ_NAME}/#{super}"
      end
    end

    Sentry::Rails.register_active_job_extension(:sidekiq, ActiveJobExtension.new)
  end
end
