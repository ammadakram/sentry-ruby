# frozen_string_literal: true

require "sentry/integrable"

module Sentry
  module TestJobsIntegration
    extend Sentry::Integrable

    register_integration name: "test_jobs", version: "1.0"
  end
end

RSpec.describe Sentry::JobExtensions::Consumer do
  let(:job) { Struct.new(:id, :queue).new("job-1", "critical") }
  let(:string_io) { StringIO.new }

  def consumer(**hooks)
    extension = Class.new(Sentry::JobExtensions::Extension) do
      define_method(:span_origin) { |job:| "auto.queue.test" }
      define_method(:integration) { |job:| Sentry::TestJobsIntegration }
      hooks.each { |hook, body| define_method(hook, &body) }
    end.new(name: "test_backend")
    described_class.new(extension: extension)
  end

  def scope
    Sentry.get_current_scope
  end

  def start_transaction(consumer, **options)
    scope.set_transaction_name("TestJob", source: :task)
    consumer.start_transaction(scope, job, **options)
  end

  def finished_transaction(consumer, **options)
    transaction = start_transaction(consumer, **options)
    consumer.finish_transaction(transaction, 200)
    sentry_events.last
  end

  def capture(consumer, exception = RuntimeError.new("boom"), **options)
    consumer.capture_exception(job, exception, **options)
    sentry_events.last
  end

  def enriching_consumer
    consumer(
      messaging_data: ->(job:) { { system: "backend", message_id: job.id, destination: job.queue, receive_latency: 42.5 } },
      retry_info: ->(job:) { { count: 3, will_retry: true } },
      scope_data: ->(job:) { { contexts: { backend: { "jid" => "backend-jid" } }, tags: { "backend.queue" => "low" }, extra: { size: 12 } } }
    )
  end

  let(:foreign_trace_id) { "a" * 32 }
  let(:foreign_trace_headers) { { "sentry-trace" => "#{foreign_trace_id}-#{"b" * 16}-1" } }

  before do
    perform_basic_setup do |config|
      config.traces_sample_rate = 1.0
      config.sdk_logger = Logger.new(string_io)
    end
    setup_sentry_test
  end

  after do
    teardown_sentry_test
  end

  describe "#start_transaction" do
    it "starts a queue.process transaction on the scope named after the scope's transaction" do
      transaction = start_transaction(consumer)

      expect(scope.get_span).to eq(transaction)
      expect(transaction.op).to eq("queue.process")
      expect(transaction.origin).to eq("auto.queue.test")
      expect(transaction.name).to eq("TestJob")
      expect(transaction.source).to eq(:task)
    end

    it "records the extension's messaging data and retry count as span data" do
      event = finished_transaction(enriching_consumer)

      expect(event.contexts.dig(:trace, :data)).to include(
        "messaging.system" => "backend",
        "messaging.message.id" => "job-1",
        "messaging.destination.name" => "critical",
        "messaging.message.receive.latency" => 42.5,
        "messaging.message.retry.count" => 3
      )
    end

    it "keeps the transaction and logs the failure when the extension's messaging data raises" do
      failing_consumer = consumer(messaging_data: ->(job:) { raise "broken messaging data" })

      event = finished_transaction(failing_consumer)

      expect(event.contexts.dig(:trace, :op)).to eq("queue.process")
      expect(scope.get_span.timestamp).not_to be_nil
      expect(string_io.string).to include("broken messaging data")
    end

    it "records the known messaging data and skips keys outside the messaging attributes" do
      event = finished_transaction(
        consumer(messaging_data: ->(job:) { { system: "backend", unknown_key: "value", destination: job.queue } })
      )

      expect(event.contexts.dig(:trace, :data)).to include(
        "messaging.system" => "backend",
        "messaging.destination.name" => "critical"
      )
      expect(event.contexts.dig(:trace, :data).values).not_to include("value")
    end

    context "when an extension collects latency only for sampled deliveries" do
      let(:job) { Struct.new(:id, :queue, :enqueued_at).new("job-1", "critical", Time.now - 5) }
      let(:sampling_consumer) do
        consumer(
          messaging_data: lambda do |job:|
            data = { system: "backend", message_id: job.id, destination: job.queue }
            data[:receive_latency] = (Time.now - job.enqueued_at) * 1_000 if Sentry.get_current_scope.get_span&.sampled
            data
          end
        )
      end

      it "records latency for a sampled delivery when the caller is unsampled" do
        scope.set_span(Sentry.start_transaction(name: "worker", op: "worker", sampled: false))

        event = finished_transaction(sampling_consumer, trace_headers: foreign_trace_headers)

        expect(event.contexts.dig(:trace, :data)).to include(
          "messaging.message.receive.latency" => a_kind_of(Numeric)
        )
      end

      it "omits latency from an unsampled delivery's error when the caller is sampled" do
        scope.set_span(Sentry.start_transaction(name: "worker", op: "worker", sampled: true))
        headers = { "sentry-trace" => "#{foreign_trace_id}-#{"b" * 16}-0" }
        transaction = start_transaction(sampling_consumer, trace_headers: headers)

        event = capture(sampling_consumer)
        sampling_consumer.finish_transaction(transaction, 500)

        expect(event.contexts.dig(:trace, :data)).to include(
          "messaging.system" => "backend",
          "messaging.message.id" => job.id,
          "messaging.destination.name" => job.queue
        )
        expect(event.contexts.dig(:trace, :data)).not_to have_key("messaging.message.receive.latency")
      end
    end

    it "continues the trace described by the trace headers" do
      transaction = start_transaction(consumer, trace_headers: foreign_trace_headers)

      expect(transaction.trace_id).to eq(foreign_trace_id)
    end

    it "keeps the scope's trace when the trace headers are empty" do
      scope_trace_id = scope.propagation_context.trace_id

      transaction = start_transaction(consumer, trace_headers: {})

      expect(scope.propagation_context.trace_id).to eq(scope_trace_id)
      expect(transaction.parent_span_id).to be_nil
    end

    it "returns nil when tracing is disabled" do
      Sentry.configuration.traces_sample_rate = nil

      expect(start_transaction(enriching_consumer)).to be_nil
    end
  end

  describe "#finish_transaction" do
    it "finishes the transaction with the status for the given HTTP status code" do
      started = consumer
      transaction = start_transaction(started)

      started.finish_transaction(transaction, 500)

      expect(sentry_events.last.contexts.dig(:trace, :status)).to eq("internal_error")
    end

    it "keeps the first completion status and sends the transaction only once" do
      started = consumer
      transaction = start_transaction(started)
      started.finish_transaction(transaction, 200)
      timestamp = transaction.timestamp

      started.finish_transaction(transaction, 500)

      expect(transaction.timestamp).to eq(timestamp)
      expect(transaction.status).to eq("ok")
      expect(sentry_events.size).to eq(1)
      expect(sentry_events.last.contexts.dig(:trace, :status)).to eq("ok")
    end

    it "ignores a missing transaction" do
      expect { consumer.finish_transaction(nil, 200) }.not_to raise_error
    end
  end

  describe "#apply_scope_data" do
    it "adds the extension's contexts, tags and extra to the scope" do
      enriching_consumer.apply_scope_data(scope, job)

      expect(scope.contexts[:backend]).to eq("jid" => "backend-jid")
      expect(scope.tags).to include("backend.queue" => "low")
      expect(scope.extra).to include(size: 12)
    end

    it "sets the user the extension supplies on the scope" do
      consumer(scope_data: ->(job:) { { user: { "id" => "42", "segment" => "beta" } } }).apply_scope_data(scope, job)

      expect(scope.user).to eq("id" => "42", "segment" => "beta")
    end
  end

  describe "#report_exception?" do
    let(:exception) { RuntimeError.new("boom") }

    it "follows the extension's decision whether the backend will retry the job or not" do
      reporting = consumer(report_exception?: ->(job:, exception:) { true }, retry_info: ->(job:) { { count: 0, will_retry: true } })
      silent = consumer(report_exception?: ->(job:, exception:) { false }, retry_info: ->(job:) { { count: 0, will_retry: false } })

      expect(reporting.report_exception?(job, exception)).to be(true)
      expect(silent.report_exception?(job, exception)).to be(false)
    end
  end

  describe "#report_retried_exception?" do
    let(:exception) { RuntimeError.new("boom") }

    it "follows the extension's decision" do
      reporting = consumer(report_retried_exception?: ->(job:, exception:) { true })

      expect(reporting.report_retried_exception?(job, exception)).to be(true)
      expect(consumer.report_retried_exception?(job, exception)).to be(false)
    end
  end

  describe "#capture_exception" do
    def error_consumer
      consumer(
        error_data: lambda do |job:, exception:|
          {
            contexts: { backend_error: { "retried" => true }, job: { "id" => "backend", "attempt" => 2 } },
            tags: { "backend.error" => "yes", queue: "backend-queue", job_id: "backend" },
            extra: { attempts: 2, size: 99 }
          }
        end
      )
    end

    it "captures the exception through the extension's integration" do
      event = capture(consumer)

      expect(event.exception.values.last.type).to eq("RuntimeError")
      expect(event.exception.values.last.mechanism.type).to eq("test_jobs")
      expect(event.sdk[:name]).to eq("sentry.ruby.test_jobs")
    end

    it "adds the extension's error data without replacing values already on the scope" do
      scope.set_contexts(job: { "id" => "scope" })
      scope.set_tags(queue: "default")
      scope.set_extras(size: 12)

      event = capture(error_consumer)

      expect(event.contexts[:backend_error]).to eq("retried" => true)
      expect(event.contexts[:job]).to eq("id" => "scope", "attempt" => 2)
      expect(event.tags).to include("backend.error" => "yes", queue: "default")
      expect(event.extra).to include(attempts: 2, size: 12)
    end

    it "keeps existing extension and user context values while adding error-specific fields" do
      refining_consumer = consumer(
        scope_data: ->(job:) { { contexts: { job: { "id" => "backend", "args" => ["raw"] } } } },
        error_data: ->(job:, exception:) { { contexts: { job: { "args" => ["filtered"], "id" => "error", "attempt" => 2 } } } }
      )
      refining_consumer.apply_scope_data(scope, job)
      scope.set_contexts(job: { "id" => "user" })

      event = capture(refining_consumer)

      expect(event.contexts[:job]).to eq("id" => "user", "args" => ["raw"], "attempt" => 2)
    end

    it "lets the caller's contexts, tags and extra win over the extension's error data" do
      event = capture(error_consumer, contexts: { job: { "id" => "caller" } }, tags: { job_id: "caller" }, extra: { attempts: 5 })

      expect(event.contexts[:job]).to eq("id" => "caller")
      expect(event.tags).to include(job_id: "caller", "backend.error" => "yes")
      expect(event.extra).to include(attempts: 5)
    end

    it "lets caller tags and extra override extension values with equivalent string or symbol keys" do
      event = capture(error_consumer, tags: { "job_id" => "caller", :"backend.error" => "caller-error" }, extra: { "attempts" => 5 })

      expect(event.tags).to eq(job_id: "caller", queue: "backend-queue", "backend.error" => "caller-error")
      expect(event.extra).to eq(attempts: 5, size: 99)
      expect(event.to_json_compatible).to include(
        "tags" => { "job_id" => "caller", "queue" => "backend-queue", "backend.error" => "caller-error" },
        "extra" => { "attempts" => 5, "size" => 99 }
      )
    end
  end
end
