# frozen_string_literal: true

module Sentry
  module JobExtensions
    # Base class for objects that let a background-job backend enrich Sentry's
    # job integrations.
    #
    # A backend gem subclasses this class and receives everything the extension
    # depends on (configuration, collaborators) through its constructor. Sentry
    # treats jobs as opaque objects: only the extension interprets the job it is
    # given.
    class Extension
      # The extension's name, used to identify it in SDK log messages.
      #
      # @return [String]
      attr_reader :name

      # @param name [String, Symbol] a non-empty name identifying the backend,
      #   stored as a frozen String
      # @raise [ArgumentError] if the name is not a non-empty String or Symbol
      def initialize(name:)
        unless (name.is_a?(String) || name.is_a?(Symbol)) && !name.empty?
          raise ArgumentError, "job extension name must be a non-empty String or Symbol, got #{name.inspect}"
        end

        @name = name.to_s.dup.freeze
      end

      # @!group Hooks
      #
      # Hooks are called directly by job integrations on the extension they
      # are given. Each hook maps its input to data and must not mutate
      # the objects it is given; the job integration applies the returned
      # data. Override only the hooks the backend can supply.

      # Data to apply to the scope the job is performed in. Called before the
      # job is performed. A supplied user replaces the user the job
      # integration sets on the scope.
      #
      # @param job [Object] the job being performed
      # @return [Hash] a Hash with any of the keys +:contexts+ (a Hash of
      #   context name to Hash), +:tags+ (a Hash), +:extra+ (a Hash) and
      #   +:user+ (a Hash). Empty by default.
      def scope_data(job:)
        {}
      end

      # Data to add to the event captured for an exception raised by the job.
      # Called when the job fails and its exception is about to be captured.
      #
      # Supplied tags and extra never replace a key already on the job's
      # scope. Each supplied context is merged into the scope's context of the
      # same name, keeping values already on the scope. Data the job integration captures
      # explicitly with the exception takes precedence over this data.
      #
      # @param job [Object] the job that failed
      # @param exception [Exception] the exception raised by the job
      # @return [Hash] a Hash with any of the keys +:contexts+ (a Hash of
      #   context name to Hash), +:tags+ (a Hash) and +:extra+ (a Hash).
      #   Empty by default.
      def error_data(job:, exception:)
        {}
      end

      # The backend's own retry state for the job. Called when the job is
      # enqueued, before it is performed, and when it fails. The hook may be
      # called several times for the same attempt, so it must not change any
      # state.
      #
      # @param job [Object] the job being enqueued, performed, or that failed
      # @return [Hash] a Hash with the keys +:count+ (a non-negative Integer,
      #   the number of retries already attempted) and +:will_retry+ (true or
      #   false, whether the backend will retry the failed attempt). By
      #   default +{ count: 0, will_retry: false }+.
      def retry_info(job:)
        { count: 0, will_retry: false }
      end

      # Whether the job integration captures the exception raised by the job.
      # Called when the job fails. Declining to capture does not change the
      # job's outcome: the job still fails and its transaction is still
      # finished as failed.
      #
      # @param job [Object] the job that failed
      # @param exception [Exception] the exception raised by the job
      # @return [Boolean] true to capture the exception. By default true
      #   only when +:will_retry+ from #retry_info is false.
      def report_exception?(job:, exception:)
        !retry_info(job: job)[:will_retry]
      end

      # Whether the job integration captures an exception that the job
      # integration's own retry mechanism rescued and retries, so the backend
      # never sees it. Called when the job integration schedules the retry.
      #
      # @param job [Object] the job being retried
      # @param exception [Exception] the exception the job raised
      # @return [Boolean] true to capture the exception. False by default.
      def report_retried_exception?(job:, exception:)
        false
      end

      # Adds trace propagation headers to the backend's job payload. Called
      # when a job is enqueued.
      #
      # @param payload [Object] the backend's job payload
      # @param headers [Hash{String => String}] the trace propagation headers
      #   to carry, such as +sentry-trace+ and +baggage+
      # @return [Object] a payload of the same class as the one given,
      #   carrying the headers. By default the given payload, unchanged.
      def inject_trace_headers(job:, payload:, headers:)
        payload
      end

      # Reads the trace propagation headers carried by the backend's job
      # payload. Called before the job is performed, to continue the trace
      # started when it was enqueued.
      #
      # @param payload [Object] the backend's job payload
      # @return [Hash{String => String}] the headers the payload carries. The
      #   job continues the trace they describe; an empty Hash continues no
      #   trace. Empty by default.
      def extract_trace_headers(job:, payload:)
        {}
      end

      # Data for the messaging attributes of the consumer span created when
      # the job is performed. Also used for the producer span created when the
      # job is enqueued unless #publish_messaging_data is overridden.
      #
      # @param job [Object] the job being enqueued or performed
      # @return [Hash] a Hash with any of the keys +:system+ (a String naming
      #   the backend), +:message_id+ (a String), +:destination+ (a String,
      #   such as the queue name), +:receive_latency+ (a Numeric, the
      #   milliseconds between enqueueing and the start of the job). Empty by
      #   default.
      def messaging_data(job:)
        {}
      end

      # Data for the messaging attributes of the producer span created when
      # the job is enqueued.
      #
      # @param job [Object] the job being enqueued
      # @return [Hash] a Hash with the keys documented on #messaging_data. By
      #   default the result of #messaging_data.
      def publish_messaging_data(job:)
        messaging_data(job: job)
      end

      # @!endgroup
    end
  end
end
