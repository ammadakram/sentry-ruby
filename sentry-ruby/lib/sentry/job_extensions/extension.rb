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
      include LoggingHelper

      PUBLISH_OP = "queue.publish"
      PROCESS_OP = "queue.process"

      MESSAGING_DATA_ATTRIBUTES = {
        system: Span::DataConventions::MESSAGING_SYSTEM,
        message_id: Span::DataConventions::MESSAGING_MESSAGE_ID,
        destination: Span::DataConventions::MESSAGING_DESTINATION_NAME,
        receive_latency: Span::DataConventions::MESSAGING_MESSAGE_RECEIVE_LATENCY,
        retry_count: Span::DataConventions::MESSAGING_MESSAGE_RETRY_COUNT
      }.freeze

      # The extension's name, used to identify it in SDK log messages.
      #
      # @return [String]
      attr_reader :name

      # @param name [String, Symbol] a non-empty name identifying the backend,
      #   stored as a frozen String
      # @raise [ArgumentError] if the name is not a non-empty String or Symbol
      def initialize(name:, integration:, origin:)
        unless (name.is_a?(String) || name.is_a?(Symbol)) && !name.empty?
          raise ArgumentError, "job extension name must be a non-empty String or Symbol, got #{name.inspect}"
        end

        @name = name.to_s.dup.freeze
        @integration = integration
        @origin = origin
      end

      def instrument_enqueue(job:, **context, &enqueue)
        return enqueue.call unless safely("decide whether to record the producer span", fallback: true) { record_publish_span?(job: job, **context) }

        enqueued = false
        begin
          Sentry.with_child_span(op: PUBLISH_OP) do |span|
            safely("record the producer span") { describe_publish_span(span, job: job, **context) } if span

            enqueued = true
            enqueue.call
          end
        rescue StandardError => e
          raise if enqueued

          log_failure("record the producer span", e)
          enqueue.call
        end
      end

      def start_job(scope:, job:, **context)
        safely("apply scope data") { apply_scope_data(scope, scope_data(job: job, **context)) }

        job_name = safely("name the transaction") { transaction_name(job: job, **context) }
        scope.set_transaction_name(job_name, source: :task) if job_name

        trace_headers = safely("extract trace headers", fallback: {}) { extract_trace_headers(job: job, **context) }
        safely("start the transaction") { start_transaction(scope, trace_headers, job: job, **context) }
      end

      def finish_job(transaction:, status:)
        return if !transaction || transaction.timestamp

        transaction.set_http_status(status)
        transaction.finish
      end

      def capture_exception(job:, exception:, contexts: {}, tags: {}, extra: {}, **context)
        captured = safely("capture the job exception", fallback: false) do
          data = merged_error_data(error_data(job: job, exception: exception, **context), contexts: contexts, tags: tags, extra: extra)
          integration(job: job, **context).capture_exception(exception, **data)
          true
        end
        return if captured

        @integration.capture_exception(exception, **capture_options(contexts: contexts, tags: tags, extra: extra))
      end

      def safely(context, fallback: nil)
        yield
      rescue StandardError => e
        log_failure(context, e)
        fallback
      end

      # @!group Hooks
      #
      # Hooks are called directly by job integrations on the extension they
      # are given. Each hook maps its input to data and must not mutate
      # the objects it is given; the job integration applies the returned
      # data. Override only the hooks the backend can supply.

      def record_publish_span?(job:, **)
        true
      end

      # Data to apply to the scope the job is performed in. Called before the
      # job is performed. A supplied user replaces the user the job
      # integration sets on the scope.
      #
      # @param job [Object] the job being performed
      # @return [Hash] a Hash with any of the keys +:contexts+ (a Hash of
      #   context name to Hash), +:tags+ (a Hash), +:extra+ (a Hash) and
      #   +:user+ (a Hash). Empty by default.
      def scope_data(job:, **)
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
      def error_data(job:, exception:, **)
        {}
      end

      # Whether the backend will retry the failed attempt.
      #
      # @param job [Object] the job that failed
      # @return [Boolean] false by default.
      def will_retry?(job:, **)
        false
      end

      # Whether the job integration captures the exception raised by the job.
      # Called when the job fails. Declining to capture does not change the
      # job's outcome: the job still fails and its transaction is still
      # finished as failed.
      #
      # @param job [Object] the job that failed
      # @param exception [Exception] the exception raised by the job
      # @return [Boolean] true to capture the exception. By default true
      #   only when #will_retry? is false.
      def report_exception?(job:, exception:, **context)
        !will_retry?(job: job, exception: exception, **context)
      end

      # Whether the job integration captures an exception that the job
      # integration's own retry mechanism rescued and retries, so the backend
      # never sees it. Called when the job integration schedules the retry.
      #
      # @param job [Object] the job being retried
      # @param exception [Exception] the exception the job raised
      # @return [Boolean] true to capture the exception. False by default.
      def report_retried_exception?(job:, exception:, **)
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
      def inject_trace_headers(job:, payload:, headers:, **)
        payload
      end

      # Reads the trace propagation headers carried by the job. Called before
      # the job is performed, to continue the trace started when it was
      # enqueued.
      #
      # @param job [Object] the job being performed
      # @return [Hash{String => String}] the headers the job carries. The
      #   job continues the trace they describe; an empty Hash continues no
      #   trace. Empty by default.
      def extract_trace_headers(job:, **)
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
      #   milliseconds between enqueueing and the start of the job) and
      #   +:retry_count+ (an Integer, the retries already attempted). Empty by
      #   default.
      def messaging_data(job:, **)
        {}
      end

      # Data for the messaging attributes of the producer span created when
      # the job is enqueued.
      #
      # @param job [Object] the job being enqueued
      # @return [Hash] a Hash with the keys documented on #messaging_data. By
      #   default the result of #messaging_data.
      def publish_messaging_data(job:, **context)
        messaging_data(job: job, **context)
      end

      def transaction_name(job:, **)
        job.class.name
      end

      def publish_description(job:, **)
        job.class.name
      end

      def span_origin(job:, **)
        @origin
      end

      def publish_span_origin(job:, **context)
        span_origin(job: job, **context)
      end

      def integration(job:, **)
        @integration
      end

      # @!endgroup

      private

      def describe_publish_span(span, job:, **context)
        span.set_description(publish_description(job: job, **context))
        span.set_origin(publish_span_origin(job: job, **context))
        set_messaging_data(span, publish_messaging_data(job: job, **context))
      end

      def start_transaction(scope, trace_headers, job:, **context)
        options = {
          name: scope.transaction_name,
          source: scope.transaction_source,
          op: PROCESS_OP,
          origin: span_origin(job: job, **context)
        }

        transaction = if trace_headers.empty?
          Sentry.start_transaction(**options)
        else
          Sentry.start_transaction(transaction: Sentry.continue_trace(trace_headers, **options), **options)
        end
        return unless transaction

        scope.set_span(transaction)
        safely("record the messaging data") { set_messaging_data(transaction, messaging_data(job: job, **context)) }

        transaction
      end

      def apply_scope_data(scope, data)
        scope.set_contexts(data[:contexts]) if data[:contexts]
        scope.set_tags(data[:tags]) if data[:tags]
        scope.set_extras(data[:extra]) if data[:extra]
        scope.set_user(data[:user]) if data[:user]
      end

      def set_messaging_data(span, data)
        data.slice(*MESSAGING_DATA_ATTRIBUTES.keys).each do |key, value|
          span.set_data(MESSAGING_DATA_ATTRIBUTES[key], value)
        end
      end

      def merged_error_data(data, contexts:, tags:, extra:)
        scope = Sentry.get_current_scope

        capture_options(
          contexts: data.fetch(:contexts, {}).to_h { |context_name, context| [context_name, context.merge(scope.contexts.fetch(context_name, {}))] }.merge(contexts),
          tags: data.fetch(:tags, {}).reject { |key, _value| scope.tags.key?(key) }.merge(tags),
          extra: data.fetch(:extra, {}).reject { |key, _value| scope.extra.key?(key) }.merge(extra)
        )
      end

      def capture_options(contexts:, tags:, extra:)
        options = { extra: extra, tags: tags, hint: { background: false } }
        options[:contexts] = contexts unless contexts.empty?
        options
      end

      def log_failure(context, error)
        log_error("Job extension #{name.inspect} failed to #{context}", error)
      end

      def sdk_logger
        Sentry.sdk_logger if Sentry.initialized?
      end
    end
  end
end
