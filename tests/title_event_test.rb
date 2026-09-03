# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require "open3"
require_relative "../scripts/codex_app_server_client"
require_relative "../scripts/title_event_store"
require_relative "../scripts/title_event_worker"
require_relative "../scripts/title_event_install"
require_relative "../scripts/title_model_decider"
require_relative "../scripts/title_pr_resolver"

class TitleEventStoreTest < Minitest::Test
  THREAD_ID = "11111111-1111-7111-8111-111111111111"

  def setup
    @dir = Dir.mktmpdir
    @store = TitleEventMaintenance::Store.new(root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_queue_debounces_and_preserves_a_newer_event_during_acknowledge
    @store.enqueue(THREAD_ID, source: "stop", now_ms: 1_000)
    assert_empty @store.snapshot(now_ms: 1_500, idle_ms: 1_000)

    snapshot = @store.snapshot(now_ms: 2_000, idle_ms: 1_000)
    assert_equal [THREAD_ID], snapshot.keys

    @store.enqueue(THREAD_ID, source: "stop", now_ms: 2_100)
    @store.acknowledge(snapshot)
    assert_equal 1, @store.queue_size
  end

  def test_retry_waits_and_second_attempt_is_counted
    @store.enqueue(THREAD_ID, source: "pr-status", now_ms: 1_000, force: true)
    first = @store.snapshot(now_ms: 1_000, idle_ms: 10_000)
    assert_equal 1, @store.mark_retry(first, error: "timeout", now_ms: 1_000, delay_ms: 600_000)
    assert_empty @store.snapshot(now_ms: 600_999, idle_ms: 0)

    second = @store.snapshot(now_ms: 601_000, idle_ms: 0)
    assert_equal 2, @store.mark_retry(second, error: "timeout again", now_ms: 601_000, delay_ms: 600_000)
  end

  def test_defer_until_idle_replaces_a_forced_event_and_preserves_it_across_old_acknowledgement
    @store.enqueue(THREAD_ID, source: "pr-status", now_ms: 1_000, force: true)
    original = @store.snapshot(now_ms: 1_000, idle_ms: 10_000)

    @store.defer_until_idle(THREAD_ID, source: "changed-during-decision", now_ms: 2_000)
    assert_empty @store.snapshot(now_ms: 2_999, idle_ms: 1_000)
    assert_equal [THREAD_ID], @store.snapshot(now_ms: 3_000, idle_ms: 1_000).keys

    @store.acknowledge(original)
    assert_equal 1, @store.queue_size
  end

  def test_reconciliation_date_uses_beijing_calendar_day
    assert_equal "2026-08-22", TitleEventMaintenance::BeijingCalendar.date(
      Time.new(2026, 8, 21, 16, 0, 0, "+00:00")
    )
  end

  def test_event_specific_delay_controls_when_queue_entry_is_due
    @store.enqueue(THREAD_ID, source: "user-prompt", now_ms: 1_000, delay_ms: 20_000)

    assert_empty @store.snapshot(now_ms: 20_999, idle_ms: 300_000)
    assert_equal [THREAD_ID], @store.snapshot(now_ms: 21_000, idle_ms: 300_000).keys
  end
end

class TitleEventHookTest < Minitest::Test
  THREAD_ID = "22222222-2222-7222-8222-222222222222"

  def test_stop_hook_enqueues_thread_without_failing_the_session
    Dir.mktmpdir do |dir|
      hook = File.expand_path("../scripts/title_event_hook.rb", __dir__)
      payload = { "hook_event_name" => "Stop", "session_id" => THREAD_ID }.to_json
      _stdout, stderr, status = Open3.capture3(
        { "CODEX_TITLE_EVENT_ROOT" => dir, "CODEX_TITLE_EVENT_DISABLE_WAKE" => "1" },
        RbConfig.ruby,
        "--disable=gems",
        hook,
        stdin_data: payload
      )
      assert status.success?, stderr
      assert_equal 1, TitleEventMaintenance::Store.new(root: dir).queue_size
    end
  end

  def test_canary_records_a_real_stop_and_writes_to_its_isolated_queue
    Dir.mktmpdir do |dir|
      hook = File.expand_path("../scripts/title_event_hook.rb", __dir__)
      marker = File.join(dir, "canary.json")
      payload = { "hook_event_name" => "Stop", "session_id" => THREAD_ID }.to_json
      _stdout, stderr, status = Open3.capture3(
        {
          "CODEX_TITLE_CANARY_PATH" => marker,
          "CODEX_TITLE_EVENT_ROOT" => dir,
          "CODEX_TITLE_EVENT_DISABLE_WAKE" => "1"
        },
        RbConfig.ruby,
        "--disable=gems",
        hook,
        stdin_data: payload
      )
      assert status.success?, stderr
      marker_payload = JSON.parse(File.read(marker))
      assert_equal "Stop", marker_payload["hook_event_name"]
      assert_equal THREAD_ID, marker_payload["thread_id"]
      assert_equal 1, TitleEventMaintenance::Store.new(root: dir).queue_size
    end
  end
  def test_prompt_and_session_start_hooks_enqueue_the_thread
    %w[UserPromptSubmit SessionStart].each do |event_name|
      Dir.mktmpdir do |dir|
        hook = File.expand_path("../scripts/title_event_hook.rb", __dir__)
        payload = { "hook_event_name" => event_name, "session_id" => THREAD_ID }.to_json
        _stdout, stderr, status = Open3.capture3(
          { "CODEX_TITLE_EVENT_ROOT" => dir, "CODEX_TITLE_EVENT_DISABLE_WAKE" => "1" },
          RbConfig.ruby,
          "--disable=gems",
          hook,
          stdin_data: payload
        )
        assert status.success?, stderr
        queue = JSON.parse(File.read(File.join(dir, "queue.json")))
        assert_includes queue.dig("threads", THREAD_ID, "sources"), event_name == "UserPromptSubmit" ? "user-prompt" : "session-start"
      end
    end
  end
end

class TitleEventInstallerTest < Minitest::Test
  def test_hook_merge_is_idempotent_and_preserves_unrelated_handlers
    old_command = "/usr/bin/ruby --disable=gems /Users/old/.codex/skills/codex-session-title-maintenance/scripts/title_event_hook.rb"
    command = "/usr/bin/ruby --disable=gems /Users/new/.codex/skills/codex-session-title-maintenance/scripts/title_event_hook.rb"
    document = {
      "hooks" => {
        "Stop" => [
          { "hooks" => [{ "command" => "other-hook", "type" => "command", "timeout" => 5 }] },
          { "hooks" => [{ "command" => old_command, "type" => "command", "timeout" => 5 }] }
        ]
      }
    }

    merged = TitleEventInstaller.merge_hook_document(document, command)
    twice = TitleEventInstaller.merge_hook_document(merged, command)
    commands = merged.dig("hooks", "Stop").flat_map { |group| group.fetch("hooks") }.map { |hook| hook["command"] }

    assert_equal ["other-hook", command], commands
    assert_equal [command], merged.dig("hooks", "SessionStart").flat_map { |group| group.fetch("hooks") }.map { |hook| hook["command"] }
    assert_equal [command], merged.dig("hooks", "UserPromptSubmit").flat_map { |group| group.fetch("hooks") }.map { |hook| hook["command"] }
    assert_equal merged, twice
  end

  def test_trust_key_quotes_the_full_hook_identity
    key = "/Users/example/.codex/hooks.json:stop:1:0"
    assert_equal %(hooks.state."#{key}".trusted_hash), TitleEventInstaller.trust_key_path(key)
  end

  def test_launch_agent_is_run_at_load_without_a_calendar_gate
    installer = TitleEventInstaller.allocate
    installer.instance_variable_set(:@app_server_bin, "/app-server")
    installer.instance_variable_set(:@decision_codex, "/codex")
    installer.instance_variable_set(:@gh_bin, "/gh")
    installer.instance_variable_set(:@codex_home, "/tmp/codex")
    installer.instance_variable_set(:@runtime_root, "/tmp/runtime")
    installer.instance_variable_set(:@worker_script, "/tmp/worker.rb")
    installer.instance_variable_set(:@label, "local.test")
    installer.instance_variable_set(:@home, "/tmp/home")

    plist = installer.send(:launch_agent_plist)

    assert_includes plist, "<key>RunAtLoad</key>"
    refute_includes plist, "StartCalendarInterval"
  end

end

class CodexAppServerClientTest < Minitest::Test
  def test_initializes_and_reads_a_thread_over_jsonl
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "fake_server.rb")
      File.write(fake, <<~RUBY)
        require "json"
        while (line = STDIN.gets)
          message = JSON.parse(line)
          next unless message["id"]
          result = if message["method"] == "initialize"
                     {"codexHome" => "/tmp", "platformFamily" => "unix", "platformOs" => "macos", "userAgent" => "fake"}
                   elsif message["method"] == "thread/read"
                     {"thread" => {"id" => message.dig("params", "threadId"), "name" => "测试标题"}}
                   else
                     {}
                   end
          STDOUT.puts(JSON.generate("id" => message["id"], "result" => result))
          STDOUT.flush
        end
      RUBY
      client = CodexAppServerClient.new(command: [RbConfig.ruby, fake])
      client.connect do |connected|
        assert_equal "测试标题", connected.read_thread("thread-id")["name"]
      end
    end
  end
end

class TitleDecisionAndPullRequestTest < Minitest::Test
  def test_title_validator_requires_one_leading_status_emoji
    decider = TitleModelDecider.new
    assert decider.valid_title?("🟡 [Project PR #123] 路由器修复")
    refute decider.valid_title?("[Project] 路由器修复")
    refute decider.valid_title?("🟡 [Project] 路由器修复 ✅")
  end

  def test_pr_urls_are_extracted_and_failed_checks_map_to_warning
    resolver = TitlePullRequestResolver.new
    candidate = {
      "title" => "🟡 [Project PR #123] 路由器修复",
      "context" => {
        "messages" => [{ "text" => "https://github.com/example-org/example-repo/pull/123" }]
      }
    }
    assert_equal [{ "repo" => "example-org/example-repo", "number" => 123 }], resolver.refs_for(candidate)
    assert_equal "⚠️", resolver.status_emoji(
      "state" => "OPEN",
      "isDraft" => false,
      "statusCheckRollup" => [{ "conclusion" => "FAILURE" }]
    )
  end

  def test_pr_number_uses_persisted_repository_url_without_reading_cwd
    resolver = TitlePullRequestResolver.new
    candidate = {
      "title" => "🔄 [Project PR #963] Alert Router RFC",
      "context" => {
        "cwd" => "/path/that/does/not/exist",
        "repository_url" => "https://github.com/example-org/example-repo.git",
        "messages" => []
      }
    }

    assert_equal [{ "repo" => "example-org/example-repo", "number" => 963 }], resolver.refs_for(candidate)
  end

  def test_multi_pr_status_prefers_active_or_blocked_over_terminal_success
    worker = TitleEventWorker.allocate

    assert_equal "✅", worker.send(:aggregate_pr_status, [{ "statusEmoji" => "✅" }, { "statusEmoji" => "✅" }])
    assert_equal "🔄", worker.send(:aggregate_pr_status, [{ "statusEmoji" => "✅" }, { "statusEmoji" => "🔄" }])
    assert_equal "⚠️", worker.send(:aggregate_pr_status, [{ "statusEmoji" => "🟡" }, { "statusEmoji" => "⚠️" }])
  end
end

class TitleEventWorkerReconciliationTest < Minitest::Test
  class FakeStore
    def with_worker_lock
      yield
      true
    end

    def read_state
      { "last_reconcile_date" => nil }
    end

    def snapshot(now_ms:, idle_ms:)
      {}
    end

    def queue_size
      0
    end
  end

  class FakeHelper
    attr_reader :options

    def prepare(**options)
      @options = options
      {
        "status" => "ready",
        "run_id" => nil,
        "window_start_ms" => options.fetch(:now_ms) - TitleMaintenance::WINDOW_MS,
        "candidates" => []
      }
    end
  end

  class EventStore < FakeStore
    def initialize(thread_id)
      @thread_id = thread_id
    end

    def read_state
      { "last_reconcile_date" => "2026-08-24" }
    end

    def snapshot(now_ms:, idle_ms:)
      {
        @thread_id => {
          "queued_at_ms" => now_ms - idle_ms,
          "revision" => 1,
          "sources" => ["stop"],
          "force" => false
        }
      }
    end
  end

  def test_daily_reconciliation_bypasses_timestamp_dedupe
    helper = FakeHelper.new
    worker = TitleEventWorker.new(
      store: FakeStore.new,
      helper: helper,
      now: -> { Time.new(2026, 8, 24, 10, 0, 0, "+08:00") }
    )

    result = worker.run(allow_outside_hours: true, dry_run: true)

    assert result["reconcile"]
    assert_equal true, helper.options[:refresh_scope]
  end

  def test_explicit_stop_event_bypasses_session_index_timestamp_dedupe_after_idle_wait
    thread_id = "33333333-3333-7333-8333-333333333333"
    helper = FakeHelper.new
    worker = TitleEventWorker.new(
      store: EventStore.new(thread_id),
      helper: helper,
      now: -> { Time.new(2026, 8, 24, 10, 0, 0, "+08:00") }
    )

    result = worker.run(allow_outside_hours: true, dry_run: true)

    refute result["reconcile"]
    assert_equal [thread_id], helper.options[:thread_ids]
    assert_equal [thread_id], helper.options[:force_thread_ids]
  end

  def test_explicit_stop_event_runs_outside_the_former_business_hours
    thread_id = "33333333-3333-7333-8333-333333333333"
    helper = FakeHelper.new
    worker = TitleEventWorker.new(
      store: EventStore.new(thread_id),
      helper: helper,
      now: -> { Time.new(2026, 8, 24, 2, 0, 0, "+08:00") }
    )

    result = worker.run(dry_run: true)

    refute result["reconcile"]
    assert_equal [thread_id], helper.options[:thread_ids]
  end

  def test_daemon_startup_warmup_is_independent_of_daily_reconciliation
    store = Class.new(FakeStore) do
      def read_state
        { "last_reconcile_date" => "2026-08-24", "last_startup_warmup_ms" => 0 }
      end
    end.new
    worker = TitleEventWorker.new(
      store: store,
      helper: FakeHelper.new,
      now: -> { Time.new(2026, 8, 24, 10, 0, 0, "+08:00") }
    )

    assert worker.send(:startup_warmup_due?, Time.new(2026, 8, 24, 10, 0, 0, "+08:00"))
  end

  def test_recent_successful_startup_warmup_prevents_restart_churn
    Dir.mktmpdir do |dir|
      store = TitleEventMaintenance::Store.new(root: dir)
      current_time = Time.new(2026, 8, 24, 10, 0, 0, "+08:00")
      now_ms = (current_time.to_r * 1000).to_i
      store.update_state { |state| state["last_startup_warmup_ms"] = now_ms - 60_000 }
      worker = TitleEventWorker.new(store: store, now: -> { current_time })

      refute worker.send(:startup_warmup_due?, current_time)
    end
  end

  def test_retryable_snapshot_keeps_due_events_that_no_longer_produce_candidates
    old_id = "33333333-3333-7333-8333-333333333333"
    candidate_id = "55555555-5555-7555-8555-555555555555"
    Dir.mktmpdir do |dir|
      store = TitleEventMaintenance::Store.new(root: dir)
      store.enqueue(old_id, source: "stop", now_ms: 1_000, force: true)
      snapshot = store.snapshot(now_ms: 2_000, idle_ms: 0)
      worker = TitleEventWorker.new(store: store)

      retryable = worker.send(:ensure_retryable_snapshot, snapshot, [{ "id" => candidate_id }], 2_000)

      assert_equal [candidate_id, old_id].sort, retryable.keys.sort
    end
  end
end

class TitleEventWorkerConcurrencyTest < Minitest::Test
  THREAD_ID = "44444444-4444-7444-8444-444444444444"
  SECOND_THREAD_ID = "66666666-6666-7666-8666-666666666666"

  class RecordingStore
    attr_reader :deferred

    def initialize
      @deferred = []
    end

    def defer_until_idle(thread_id, source:, now_ms:)
      @deferred << { "id" => thread_id, "source" => source, "now_ms" => now_ms }
    end
  end

  class RecordingHelper
    attr_reader :records

    def initialize
      @records = []
    end

    def record(**options)
      @records << options
    end

    def lookup(_thread_id, **_options)
      { "updated_at_ms" => 2_001 }
    end
  end

  class ChangingClient
    attr_reader :set_calls

    def initialize(thread)
      @thread = thread
      @set_calls = []
    end

    def connect
      self
    end

    def read_thread(_thread_id)
      @thread
    end

    def set_thread_name(thread_id, title)
      @set_calls << [thread_id, title]
    end

    def close; end
  end

  class SplittingDecider
    attr_reader :batch_sizes

    def initialize(always_fail: false)
      @always_fail = always_fail
      @batch_sizes = []
    end

    def valid_title?(_title)
      false
    end

    def decide(candidates)
      @batch_sizes << candidates.length
      if @always_fail || candidates.length > 1
        raise TitleModelDecider::InvalidDecisionError, "decision ids do not match candidates"
      end

      [{ "id" => candidates.first["id"], "action" => "keep", "title" => nil }]
    end
  end

  def test_changed_native_or_manual_title_discards_stale_decision_and_requeues
    store = RecordingStore.new
    helper = RecordingHelper.new
    client = ChangingClient.new(
      "name" => "用户刚改的新标题",
      "updatedAt" => 101,
      "status" => { "type" => "idle" }
    )
    worker = TitleEventWorker.new(
      store: store,
      helper: helper,
      app_client_factory: -> { client }
    )
    candidate = {
      "id" => THREAD_ID,
      "title" => "Codex 原生标题",
      "updated_at_ms" => 1_000,
      "live_version" => {
        "name" => "Codex 原生标题",
        "updatedAt" => 100,
        "status" => { "type" => "idle" }
      }
    }
    decision = { "id" => THREAD_ID, "action" => "rename", "title" => "🔄 条件更新标题" }

    outcomes = worker.send(:apply_decisions, "run-id", [candidate], [decision], 2_000)

    assert_equal "deferred", outcomes.first["action"]
    assert_empty client.set_calls
    assert_empty helper.records
    assert_equal "changed-during-decision", store.deferred.first["source"]
  end

  def test_active_prompt_can_update_title_while_thread_timestamp_is_advancing
    store = RecordingStore.new
    helper = RecordingHelper.new
    client = ChangingClient.new(
      "name" => "旧目标",
      "updatedAt" => 101,
      "status" => { "type" => "active" }
    )
    worker = TitleEventWorker.new(
      store: store,
      helper: helper,
      app_client_factory: -> { client }
    )
    candidate = {
      "id" => THREAD_ID,
      "title" => "旧目标",
      "updated_at_ms" => 1_000,
      "event_sources" => ["user-prompt"],
      "pull_requests" => [],
      "live_version" => {
        "name" => "旧目标",
        "updatedAt" => 100,
        "status" => { "type" => "active" }
      }
    }
    decision = { "id" => THREAD_ID, "action" => "rename", "title" => "🔄 新目标" }

    outcomes = worker.send(:apply_decisions, "run-id", [candidate], [decision], 2_000)

    assert_equal "rename", outcomes.first["action"]
    assert_equal [[THREAD_ID, "🔄 新目标"]], client.set_calls
  end

  def test_attach_live_versions_collects_named_threads_without_filter_map
    store = RecordingStore.new
    client = ChangingClient.new(
      "name" => "Codex 原生标题",
      "updatedAt" => 100,
      "status" => { "type" => "idle" }
    )
    worker = TitleEventWorker.new(store: store, app_client_factory: -> { client })

    candidates = worker.send(:attach_live_versions, [{ "id" => THREAD_ID }], 2_000)

    assert_equal ["Codex 原生标题"], candidates.map { |candidate| candidate["title"] }
  end

  def test_daemon_wait_can_be_woken_without_waiting_for_the_timeout
    worker = TitleEventWorker.allocate
    reader, writer = IO.pipe
    worker.instance_variable_set(:@wake_reader, reader)
    worker.instance_variable_set(:@wake_writer, writer)
    notifier = Thread.new do
      sleep 0.02
      writer.write(".")
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    worker.send(:wait_for_wake, 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.5
  ensure
    notifier&.join
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end


  def test_invalid_batch_is_split_without_blocking_valid_singletons
    decider = SplittingDecider.new
    worker = TitleEventWorker.new(store: RecordingStore.new, decider: decider)
    candidates = [THREAD_ID, SECOND_THREAD_ID].map do |id|
      { "id" => id, "title" => "原生标题", "pull_requests" => [] }
    end

    decisions = worker.send(:decisions_for, candidates, {}, 2_000)

    assert_equal [2, 1, 1], decider.batch_sizes
    assert_equal ["keep", "keep"], decisions.map { |decision| decision["action"] }
  end

  def test_invalid_singleton_is_deferred_without_failing_other_work
    store = RecordingStore.new
    worker = TitleEventWorker.new(store: store, decider: SplittingDecider.new(always_fail: true))
    candidate = { "id" => THREAD_ID, "title" => "原生标题", "pull_requests" => [] }

    decisions = worker.send(:decisions_for, [candidate], {}, 2_000)

    assert_equal "deferred", decisions.first["action"]
    assert_equal "invalid-model-decision", store.deferred.first["source"]
  end
  def test_active_prompt_decision_cannot_claim_non_pr_completion
    worker = TitleEventWorker.allocate
    candidate = {
      "id" => THREAD_ID,
      "event_sources" => ["user-prompt"],
      "pull_requests" => []
    }
    decision = { "id" => THREAD_ID, "action" => "rename", "title" => "✅ 完成迁移" }

    normalized = worker.send(:normalize_provisional_decisions, [candidate], [decision])

    assert_equal "🔄 完成迁移", normalized.first["title"]
  end
end
