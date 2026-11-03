# frozen_string_literal: true

require "sentry/sidekiq/job_extension"

module Sentry
  module Sidekiq
    module ActiveJobSupport
      RESERVED_KEY_PREFIX = /^_aj_/

      def self.handles?(job)
        job.is_a?(Hash) && job.key?("wrapped")
      end

      class JobExtension < Sentry::Sidekiq::JobExtension
        def transaction_name(job:, **)
          "#{SIDEKIQ_NAME}/#{job["wrapped"]}"
        end

        def error_context(context)
          strip_reserved_keys(super)
        end

        private

        def strip_reserved_keys(value)
          case value
          when Array
            value.map { |item| strip_reserved_keys(item) }
          when Hash
            value.to_h { |key, item| [reserved_key?(key) ? key.to_s.sub(RESERVED_KEY_PREFIX, "") : key, strip_reserved_keys(item)] }
          else
            defined?(::GlobalID) && value.is_a?(::GlobalID) ? value.to_s : value
          end
        end

        def reserved_key?(key)
          key.to_s.match?(RESERVED_KEY_PREFIX)
        end
      end
    end
  end
end
