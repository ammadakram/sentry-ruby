# frozen_string_literal: true

module Sentry
  module Sidekiq
    class Producer < Sentry::JobExtensions::Producer
      private

      def describe_span(span, job)
        span.set_description(extension.publish_description(job: job))
        set_messaging_data(span, extension.publish_messaging_data(job: job))
      end
    end
  end
end
