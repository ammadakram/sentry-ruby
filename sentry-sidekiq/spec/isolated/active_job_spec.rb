# frozen_string_literal: true

require_relative "support/rails_app"
require "active_job/railtie"
require "sidekiq/api"

RSpec.describe "ActiveJob jobs on Sidekiq when the Sidekiq adapter is not skippable" do
  let(:processor) { new_processor }
  let(:transport) { Sentry.get_current_client.transport }

  let(:succeeding_job) do
    stub_const("SucceedingJob", Class.new(ActiveJob::Base) do
      self.queue_adapter = :sidekiq
      queue_as :events

      def perform(*); end
    end)
  end

  let(:failing_job) do
    stub_const("FailingJob", Class.new(ActiveJob::Base) do
      self.queue_adapter = :sidekiq
      queue_as :events

      def perform(*)
        raise "job failed"
      end
    end)
  end

  before do
    make_basic_app do |config|
      config.traces_sample_rate = 1.0
      config.rails.skippable_job_adapters.delete("ActiveJob::QueueAdapters::SidekiqAdapter")
    end
  end

  def sidekiq_message(job_class, *arguments, **attributes)
    job = job_class.new(*arguments)
    enqueued_at = WITH_SIDEKIQ_8 ? now_in_ms : Time.now.to_f
    {
      "class" => ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.to_s,
      "wrapped" => job_class.name,
      "queue" => job.queue_name,
      "args" => [job.serialize],
      "jid" => SecureRandom.hex(12),
      "retry" => false,
      "created_at" => enqueued_at,
      "enqueued_at" => enqueued_at
    }.merge(attributes.transform_keys(&:to_s))
  end

  def deliver(message)
    transport.events.clear
    process_work(processor, Sidekiq::BasicFetch::UnitOfWork.new("queue:#{message["queue"]}", Sidekiq.dump_json(message)))
    transport.events.dup
  end

  def consumer_transactions(events)
    events.select { |event| event.is_a?(Sentry::TransactionEvent) && event.contexts.dig(:trace, :op) == "queue.process" }
  end

  it "reports the job once through sentry-rails under Sidekiq's transaction name and origin" do
    transactions = consumer_transactions(deliver(sidekiq_message(succeeding_job)))

    expect(transactions.size).to eq(1)
    expect(transactions.first.transaction).to eq("Sidekiq/SucceedingJob")
    expect(transactions.first.contexts.dig(:trace, :origin)).to eq("auto.queue.sidekiq")
    expect(transactions.first.contexts[:active_job]).to include(job_class: "SucceedingJob", queue: "events")
  end

  it "captures a failing job once with its ActiveJob context" do
    message = sidekiq_message(failing_job)

    events = deliver(message)

    errors = events.grep(Sentry::ErrorEvent)
    expect(errors.size).to eq(1)
    expect(errors.first.transaction).to eq("Sidekiq/FailingJob")
    expect(errors.first.contexts[:active_job]).to include(job_class: "FailingJob", provider_job_id: message["jid"])
    expect(errors.first.contexts.dig(:trace, :span_id)).to eq(consumer_transactions(events).first.contexts.dig(:trace, :span_id))
  end

  it "captures an error raised before the job runs once through sentry-sidekiq" do
    message = sidekiq_message(succeeding_job, retry: false)
    message["wrapped"] = "RemovedJob"
    message["args"].first["job_class"] = "RemovedJob"

    errors = deliver(message).grep(Sentry::ErrorEvent)

    expect(errors.size).to eq(1)
    expect(errors.first.exception.values.first.mechanism.type).to eq("sidekiq")
    expect(errors.first.contexts[:sidekiq]).to include("jid" => message["jid"], "queue" => "events")
  end

  it "continues the trace of the transaction that enqueued the job" do
    queue = Sidekiq::Queue.new("events")
    queue.clear
    parent = Sentry.start_transaction(name: "enqueuer", op: "test")
    Sentry.get_current_scope.set_span(parent)

    succeeding_job.perform_later("sku")

    parent.finish
    Sentry.get_current_scope.clear
    transaction = consumer_transactions(deliver(queue.first.item)).first
    queue.clear

    expect(transaction.contexts[:trace]).to include(trace_id: parent.trace_id)
  end

  it "keeps reporting plain Sidekiq workers through sentry-sidekiq" do
    transport.events.clear

    execute_worker(processor, HappyWorker)

    transaction = consumer_transactions(transport.events).first
    expect(transaction.transaction).to eq("Sidekiq/HappyWorker")
    expect(transaction.contexts).not_to have_key(:active_job)
  end
end
