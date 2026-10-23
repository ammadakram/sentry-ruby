# frozen_string_literal: true

module Sentry
  module Rails
    class ActiveJobExtension
      class Consumer < Sentry::JobExtensions::Consumer
        public :safely
      end
    end
  end
end
