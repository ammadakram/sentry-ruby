# frozen_string_literal: true

module Sentry
  module Sidekiq
    class Consumer < Sentry::JobExtensions::Consumer
      public :safely
    end
  end
end
