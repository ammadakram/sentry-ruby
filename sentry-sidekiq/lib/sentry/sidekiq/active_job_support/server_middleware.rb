# frozen_string_literal: true

module Sentry
  module Sidekiq
    module ActiveJobSupport
      ACTIVE_JOB_ADAPTER = "ActiveJob::QueueAdapters::SidekiqAdapter"

      module ServerMiddleware
        def call(worker, job, queue)
          return yield if ActiveJobSupport.handles?(job)

          super
        end
      end
    end
  end
end
