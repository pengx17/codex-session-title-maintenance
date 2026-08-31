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

  def test_business_hours_are_beijing_weekdays_only
    assert TitleEventMaintenance::BusinessHours.open?(Time.new(2026, 8, 21, 9, 0, 0, "+08:00"))
    assert TitleEventMaintenance::BusinessHours.open?(Time.new(2026, 8, 21, 18, 0, 0, "+08:00"))
    refute TitleEventMaintenance::BusinessHours.open?(Time.new(2026, 8, 21, 18, 1, 0, "+08:00"))
    refute TitleEventMaintenance::BusinessHours.open?(Time.new(2026, 8, 22, 10, 0, 0, "+08:00"))
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
    assert_equal merged, twice
  end

  def test_trust_key_quotes_the_full_hook_identity
    key = "/Users/example/.codex/hooks.json:stop:1:0"
    assert_equal %(hooks.state."#{key}".trusted_hash), TitleEventInstaller.trust_key_path(key)
  end

  def test_beijing_nine_maps_to_tokyo_ten
    tokyo = Time.new(2026, 8, 24, 12, 0, 0, "+09:00")
    assert_equal({ "Hour" => 10, "Minute" => 0, "Weekday" => 1 }, TitleEventInstaller.local_start(tokyo))
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
end

class TitleEventWorkerConcurrencyTest < Minitest::Test
  THREAD_ID = "44444444-4444-7444-8444-444444444444"

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
end
