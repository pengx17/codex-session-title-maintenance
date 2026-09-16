# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/title_event_worker"

class TitleTaskWorkerTest < Minitest::Test
  ID = "11111111-1111-7111-8111-111111111111"
  OTHER = "22222222-2222-7222-8222-222222222222"

  class Helper
    attr_accessor :candidates, :lookup_error
    def initialize(candidates)
      @candidates = candidates
    end
    def prepare(**options)
      ids = options[:thread_ids]
      { "status" => "ready", "candidates" => @candidates.select { |c| ids.nil? || ids.include?(c["id"]) } }
    end
    def lookup(id, **options)
      raise @lookup_error if @lookup_error
      { "id" => id, "title" => options[:expect_title] }
    end
  end

  class Client
    attr_reader :writes, :names
    attr_accessor :on_write, :readback_mismatch
    def initialize
      @names = Hash.new("原生标题")
      @writes = []
    end
    def connect; self; end
    def close; end
    def read_thread(id)
      { "name" => @names[id], "status" => { "type" => "notLoaded" }, "updatedAt" => Time.now.to_f }
    end
    def set_thread_name(id, title)
      @writes << [id, title]
      @names[id] = title unless @readback_mismatch
      @on_write.call(id) if @on_write
    end
  end

  def setup
    @dir = Dir.mktmpdir("title-worker-contract-")
    @time = Time.utc(2026, 9, 16, 1)
    @events = TitleEventMaintenance::Store.new(root: File.join(@dir, "events"))
    @tasks = TitleTaskStore.new(root: File.join(@dir, "tasks"))
    @client = Client.new
    @paths = { ID => File.join(@dir, "one.jsonl"), OTHER => File.join(@dir, "two.jsonl") }
    @paths.each_value { |path| File.write(path, transcript_record("维护标题")) }
    @helper = Helper.new(@paths.map { |id, path| { "id" => id, "rollout_path" => path } })
    @events.update_state do |state|
      state["last_reconcile_date"] = TitleEventMaintenance::BeijingCalendar.date(@time)
      state["last_pr_poll_ms"] = millis
    end
    @model_calls = []
    @during_model = nil
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def millis
    (@time.to_r * 1000).to_i
  end

  def transcript_record(text, role: "user", phase: nil)
    JSON.generate("type" => "response_item", "payload" => {
      "type" => "message", "role" => role, "phase" => phase, "content" => [{ "text" => text }]
    }) + "\n"
  end

  def enqueue(id = ID, source: "stop")
    @events.enqueue(id, source: source, now_ms: millis, force: true)
  end

  def engine
    owner = self
    model = Object.new
    model.define_singleton_method(:update) { |**args| owner.update_model(args) }
    TitleTaskEngine.new(store: @tasks, model: model, now: -> { millis })
  end

  def update_model(args)
    @model_calls << args[:messages].map { |m| m["id"] }
    @during_model.call(args) if @during_model
    first = args[:messages].find { |m| m["role"] == "user" }
    existing = args[:task]["goal"]
    { "goal" => { "action" => existing ? "retain" : "start", "topic" => existing ? "" : "维护标题",
                  "project" => "", "evidence" => existing ? [] : [{ "message_id" => first["id"], "quote" => first["text"] }] },
      "requirements" => [], "pull_requests" => [], "progress" => nil }
  end

  def run_worker
    TitleEventWorker.new(store: @events, helper: @helper, engine: engine,
      app_client_factory: -> { @client }, now: -> { @time }, owner_thread_id: nil).run
  end

  def outcomes(result)
    assert_equal "finished", result["status"], result.inspect
    result.fetch("outcomes")
  end

  def test_incomplete_checkpoint_keeps_event_and_restart_resumes_without_duplicate_messages
    File.write(@paths[ID], (0...101).map { |i| transcript_record("维护标题 #{i}") }.join)
    enqueue
    assert_equal "deferred", outcomes(run_worker).first["action"]
    assert_equal 1, @events.queue_size
    refute @tasks.load(ID)["caught_up"]
    assert_empty @client.writes
    @time += 2
    assert_equal "rename", outcomes(run_worker).first["action"]
    assert_equal 0, @events.queue_size
    assert @tasks.load(ID)["caught_up"]
    ids = @model_calls.flatten
    assert_equal 101, ids.length
    assert_equal ids.length, ids.uniq.length
  end

  def test_new_prompt_during_model_survives_without_stale_write_or_retry_overwrite
    event = enqueue
    @during_model = ->(_) { @events.enqueue(ID, source: "user-prompt", now_ms: millis + 1, delay_ms: 20_000) }
    result = outcomes(run_worker).first
    assert_equal "changed_before_write", result["reason"]
    assert_empty @client.writes
    current = JSON.parse(File.read(@events.queue_path)).dig("threads", ID)
    assert_operator current["revision"], :>, event["revision"]
    assert_equal ["user-prompt"], current["sources"]
    assert_equal 0, current["attempts"]
  end

  def test_new_prompt_during_title_write_survives_ack_and_is_processed_next
    enqueue
    @client.on_write = ->(_) { @events.enqueue(ID, source: "user-prompt", now_ms: millis + 1, delay_ms: 20_000) }
    assert_equal "changed_after_write", outcomes(run_worker).first["reason"]
    assert_equal 1, @events.queue_size
    assert_equal "rename", @tasks.load(ID).dig("last_applied", "disposition")
    @client.on_write = nil
    @time += 21
    assert_equal "keep", outcomes(run_worker).first["action"]
    assert_equal 0, @events.queue_size
  end

  def test_not_loaded_prompt_remains_active_despite_timestamp_advancement
    enqueue(source: "user-prompt")
    assert_equal "rename", outcomes(run_worker).first["action"]
    assert_match(/^🔄/, @client.names[ID])
    assert_equal 0, @events.queue_size
    # Lifecycle remains available after ACK for a later reconciliation.
    assert_equal "user-prompt", @events.lifecycle(ID)["source"]
  end

  def test_missing_index_event_is_retained_and_does_not_block_other_task
    @helper.candidates.reject! { |c| c["id"] == ID }
    enqueue
    enqueue(OTHER)
    results = outcomes(run_worker).each_with_object({}) { |r, h| h[r["id"]] = r }
    assert_equal "error", results[ID]["action"]
    assert_equal "rename", results[OTHER]["action"]
    assert @events.event_revision(ID)
    assert_nil @events.event_revision(OTHER)
    assert_nil @tasks.load(ID)["cursor"]
  end

  def test_task_model_failure_does_not_block_other_task_or_advance_failed_cursor
    File.write(@paths[ID], transcript_record("失败任务"))
    @during_model = ->(args) { raise "provider failure" if args[:messages].any? { |m| m["text"] == "失败任务" } }
    enqueue
    enqueue(OTHER)
    results = outcomes(run_worker).each_with_object({}) { |r, h| h[r["id"]] = r }
    assert_equal "error", results[ID]["action"]
    assert_equal "rename", results[OTHER]["action"]
    assert_nil @tasks.load(ID)["cursor"]
    assert @events.event_revision(ID)
    assert_nil @events.event_revision(OTHER)
  end

  def test_manual_title_change_during_model_is_not_overwritten
    enqueue
    @during_model = ->(_) { @client.names[ID] = "用户手动标题" }
    assert_equal "changed_before_write", outcomes(run_worker).first["reason"]
    assert_equal "用户手动标题", @client.names[ID]
    assert_empty @client.writes
    assert @events.event_revision(ID)
  end

  def test_readback_mismatch_does_not_ack_or_record_applied_title
    enqueue
    @client.readback_mismatch = true
    result = outcomes(run_worker).first
    assert_equal "error", result["action"]
    assert_match(/readback mismatch/, result["error"])
    assert @events.event_revision(ID)
    assert_nil @tasks.load(ID)["last_applied"]
  end

  def test_index_readback_failure_restarts_from_committed_cursor_and_rechecks_title
    enqueue
    @helper.lookup_error = "index write not visible"
    assert_equal "error", outcomes(run_worker).first["action"]
    assert @tasks.load(ID)["caught_up"]
    assert_nil @tasks.load(ID)["last_applied"]
    assert @events.event_revision(ID)
    @helper.lookup_error = nil
    @time += 601
    assert_equal "keep", outcomes(run_worker).first["action"]
    assert_equal 1, @model_calls.length
    assert_equal 0, @events.queue_size
  end

  def test_active_provisional_write_retains_unconsumed_assistant_result
    enqueue(source: "user-prompt")
    @during_model = ->(_) do
      File.open(@paths[ID], "ab") { |file| file.write(transcript_record("最终验收尚未完成", role: "assistant", phase: "final")) }
    end
    outcomes(run_worker)
    assert_match(/^🔄/, @client.names[ID]) # Publishing a provisional title remains allowed.
    assert_operator @tasks.load(ID).dig("cursor", "offset"), :<, File.size(@paths[ID])
    assert @events.event_revision(ID), "unconsumed assistant evidence must remain scheduled even if Stop is delayed or missed"
  end

  def test_acknowledged_lifecycle_rejects_older_stop_after_store_restart
    recent = @events.enqueue(ID, source: "user-prompt", now_ms: millis + 100, force: true)
    @events.acknowledge(ID => recent)
    restarted = TitleEventMaintenance::Store.new(root: @events.root)
    restarted.enqueue(ID, source: "stop", now_ms: millis + 50, force: true)
    assert_equal "user-prompt", restarted.lifecycle(ID)["source"]
    assert_equal 0, restarted.queue_size
  end

  def test_newer_lifecycle_is_not_discarded_by_more_recent_pr_poll_timestamp
    @events.enqueue(ID, source: "user-prompt", now_ms: millis, force: true)
    @events.enqueue(ID, source: "pr-status", now_ms: millis + 200, force: true)
    @events.enqueue(ID, source: "stop", now_ms: millis + 100, delay_ms: 90_000)
    assert_equal "stop", @events.lifecycle(ID)["source"], "order lifecycle events against lifecycle timestamps, not PR poll timestamps"
    current = JSON.parse(File.read(@events.queue_path)).dig("threads", ID)
    assert_equal ["pr-status", "stop"], current["sources"]
    refute current["force"]
  end

  def test_corrupt_checkpoint_does_not_block_unrelated_work_during_pr_poll
    File.write(File.join(@tasks.root, "#{OTHER}.json"), "{broken}")
    @events.update_state { |state| state["last_pr_poll_ms"] = 0 }
    enqueue(ID)
    result = run_worker
    assert_equal "finished", result["status"], "PR polling must isolate corrupt task checkpoints: #{result.inspect}"
    assert_equal "rename", result.fetch("outcomes").find { |entry| entry["id"] == ID }["action"]
    assert_nil @events.event_revision(ID)
    assert_equal "{broken}", File.read(File.join(@tasks.root, "#{OTHER}.json"))
  end

  def test_legacy_title_automation_is_excluded_without_model_or_name_write
    File.write(@paths[ID], transcript_record("Automation ID: codex-session-title-maintenance"))
    enqueue(ID)
    assert_equal "excluded", outcomes(run_worker).first["action"]
    assert_empty @model_calls
    assert_empty @client.writes
    assert_nil @events.event_revision(ID)
  end
end
