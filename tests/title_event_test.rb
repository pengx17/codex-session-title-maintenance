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
    assert_match(/<key>ProcessType<\/key>\s*<string>Standard<\/string>/, plist)
    refute_includes plist, "<key>LowPriorityIO</key>"
  end

  def test_install_retires_the_old_launch_agent_plist
    Dir.mktmpdir do |home|
      launch_agents = File.join(home, "Library", "LaunchAgents")
      FileUtils.mkdir_p(launch_agents)
      legacy_path = File.join(launch_agents, "com.pengx17.codex-title-maintenance.plist")
      File.write(legacy_path, "legacy")
      installer = TitleEventInstaller.allocate
      installer.instance_variable_set(:@home, home)
      installer.instance_variable_set(:@label, TitleEventInstaller::DEFAULT_LABEL)
      installer.instance_variable_set(:@now, -> { Time.utc(2026, 9, 3) })
      unavailable = Object.new
      unavailable.define_singleton_method(:success?) { false }
      Open3.stub(:capture3, ["", "", unavailable]) do
        retired = installer.send(:retire_legacy_launch_agents)

        assert_equal ["com.pengx17.codex-title-maintenance"], retired.map { |item| item["label"] }
        refute File.exist?(legacy_path)
        assert File.exist?("#{legacy_path}.retired")
      end
    end
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

end
