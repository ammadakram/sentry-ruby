# frozen_string_literal: true

RSpec.describe Sentry::JobExtensions::Producer do
  let(:job) { Struct.new(:id, :queue).new("job-1", "critical") }
  let(:string_io) { StringIO.new }

  def producer(**hooks)
    extension = Class.new(Sentry::JobExtensions::Extension) do
      define_method(:span_origin) { |job:| "auto.queue.test" }
      define_method(:publish_description) { |job:| "TestJob" }
      hooks.each { |hook, body| define_method(hook, &body) }
    end.new(name: "test_backend")
    described_class.new(extension: extension)
  end

  def enriching_producer
    producer(
      messaging_data: ->(job:) { { system: "backend", message_id: job.id, destination: job.queue, receive_latency: 42.5 } },
      retry_info: ->(job:) { { count: 3, will_retry: true } }
    )
  end

  def within_transaction
    transaction = Sentry.start_transaction(name: "parent", op: "test")
    Sentry.get_current_scope.set_span(transaction)
    yield
  ensure
    transaction.finish
  end

  def publish_span
    sentry_events.last.spans.find { |span| span[:op] == "queue.publish" }
  end

  def record_span(producer, &enqueue)
    producer.record_span(job, &(enqueue || -> { :enqueued }))
  end

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

  describe "#record_span" do
    it "records a queue.publish span with the extension's identity, messaging data and retry count around the enqueue" do
      result = within_transaction { record_span(enriching_producer) }

      expect(result).to eq(:enqueued)
      expect(publish_span).to include(description: "TestJob", origin: "auto.queue.test")
      expect(publish_span[:data]).to include(
        "messaging.system" => "backend",
        "messaging.message.id" => "job-1",
        "messaging.destination.name" => "critical",
        "messaging.message.receive.latency" => 42.5,
        "messaging.message.retry.count" => 3
      )
    end

    it "enqueues without a span when no transaction is active" do
      expect(record_span(enriching_producer)).to eq(:enqueued)
      expect(sentry_events).to be_empty
    end

    it "logs an instrumentation failure and enqueues the job exactly once" do
      failing = producer(publish_messaging_data: ->(job:) { raise "boom from instrumentation" })
      enqueued = 0

      result = within_transaction { record_span(failing) { enqueued += 1 } }

      expect(result).to eq(1)
      expect(enqueued).to eq(1)
      expect(string_io.string).to include("test_backend", "boom from instrumentation")
    end

    it "propagates a failing enqueue" do
      expect do
        within_transaction { record_span(enriching_producer) { raise "boom from enqueue" } }
      end.to raise_error(RuntimeError, /boom from enqueue/)
    end
  end

  describe "#inject_trace_headers" do
    let(:payload) { { "job_class" => "TestJob" } }
    let(:headers) { { "sentry-trace" => "trace" } }

    it "returns the payload the extension built with the headers" do
      extension_producer = producer(inject_trace_headers: ->(job:, payload:, headers:) { payload.merge("trace" => headers) })

      expect(extension_producer.inject_trace_headers(job, payload, headers)).to eq(
        "job_class" => "TestJob", "trace" => headers
      )
    end
  end
end
