# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "yaml"
require_relative "../scripts/title_maintenance"

class TitleMaintenanceTest < Minitest::Test
  NOW_MS = 1_800_000_000_000

  def setup
    @dir = Dir.mktmpdir
    @index = File.join(@dir, "session_index.jsonl")
    @state = File.join(@dir, "state.yml")
    @lock = File.join(@dir, "lock.json")
    @pinned = File.join(@dir, "pinned.txt")
    @sessions = File.join(@dir, "sessions")
    Dir.mkdir(@sessions)
    File.write(@state, YAML.dump("retry_pending" => false, "threads" => {}))
    File.write(@pinned, "pinned-id\n")
    @helper = TitleMaintenance.new(
      index: @index,
      state: @state,
      lock: @lock,
      pinned: @pinned,
      session_roots: [@sessions],
      owner_id: "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_prepare_includes_recent_and_old_pinned_but_excludes_automation_and_owner
    write_index([
      entry("recent-id", NOW_MS - 1_000, "普通任务"),
      entry("pinned-id", NOW_MS - 2 * TitleMaintenance::WINDOW_MS, "旧置顶任务"),
      entry("old-id", NOW_MS - 2 * TitleMaintenance::WINDOW_MS, "旧任务"),
      entry("automation-id", NOW_MS - 1_000, TitleMaintenance::AUTOMATION_TITLE),
      entry("aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa", NOW_MS - 1_000, "owner")
    ])

    result = @helper.prepare(now_ms: NOW_MS, dry_run: true)

    assert_equal %w[pinned-id recent-id], result["candidates"].map { |item| item["id"] }.sort
    assert_equal %w[pinned], result["candidates"].find { |item| item["id"] == "pinned-id" }["reasons"]
  end

  def test_strict_timestamp_deduplication
    write_index([entry("recent-id", NOW_MS - 1_000, "普通任务")])
    File.write(@state, YAML.dump("retry_pending" => false, "threads" => { "recent-id" => { "updated_at_ms" => NOW_MS - 1_000, "disposition" => "kept" } }))

    result = @helper.prepare(now_ms: NOW_MS, dry_run: true)

    assert_empty result["candidates"]
  end

  def test_targeted_prepare_only_returns_requested_threads
    write_index([
      entry("first-id", NOW_MS - 1_000, "第一个任务"),
      entry("second-id", NOW_MS - 2_000, "第二个任务")
    ])

    result = @helper.prepare(now_ms: NOW_MS, dry_run: true, thread_ids: ["second-id"])

    assert_equal ["second-id"], result["candidates"].map { |item| item["id"] }
  end

  def test_forced_thread_bypasses_window_and_timestamp_dedupe
    write_index([entry("old-id", NOW_MS - 2 * TitleMaintenance::WINDOW_MS, "🟡 [Project PR #1] 旧任务")])
    File.write(@state, YAML.dump(
      "retry_pending" => false,
      "threads" => { "old-id" => { "updated_at_ms" => NOW_MS, "disposition" => "kept" } }
    ))

    result = @helper.prepare(
      now_ms: NOW_MS,
      dry_run: true,
      thread_ids: ["old-id"],
      force_thread_ids: ["old-id"]
    )

    assert_equal ["old-id"], result["candidates"].map { |item| item["id"] }
    assert_includes result.dig("candidates", 0, "reasons"), "forced"
  end

  def test_refresh_scope_bypasses_dedupe_without_expanding_the_window
    write_index([
      entry("recent-id", NOW_MS - 1_000, "近期任务"),
      entry("old-id", NOW_MS - 2 * TitleMaintenance::WINDOW_MS, "历史任务")
    ])
    File.write(@state, YAML.dump(
      "retry_pending" => false,
      "threads" => {
        "recent-id" => { "updated_at_ms" => NOW_MS, "disposition" => "kept" },
        "old-id" => { "updated_at_ms" => NOW_MS, "disposition" => "kept" }
      }
    ))

    result = @helper.prepare(now_ms: NOW_MS, dry_run: true, refresh_scope: true)

    assert_equal ["recent-id"], result["candidates"].map { |item| item["id"] }
    assert_includes result.dig("candidates", 0, "reasons"), "refresh"
  end

  def test_record_finish_and_retry_lifecycle
    write_index([entry("recent-id", NOW_MS - 1_000, "普通任务")])
    prepared = @helper.prepare(now_ms: NOW_MS)
    run_id = prepared.fetch("run_id")
    @helper.record(run_id: run_id, thread_id: "recent-id", updated_at_ms: NOW_MS, disposition: "renamed")
    @helper.finish(run_id: run_id, now_ms: NOW_MS, window_start_ms: NOW_MS - TitleMaintenance::WINDOW_MS)
    state = YAML.load_file(@state)

    assert_equal NOW_MS, state.dig("threads", "recent-id", "updated_at_ms")
    assert_equal false, state["retry_pending"]
    refute File.exist?(@lock)

    second = @helper.prepare(now_ms: NOW_MS + 3_600_000)
    @helper.defer_retry(run_id: second.fetch("run_id"), now_ms: NOW_MS + 3_600_000)
    state = YAML.load_file(@state)
    assert_equal true, state["retry_pending"]
    assert_equal NOW_MS + 3_600_000 + 600_000, state["retry_not_before_ms"]
  end

  def test_retry_slot_requires_due_retry_for_same_hour
    write_index([])
    File.write(@state, YAML.dump(
      "retry_pending" => true,
      "retry_not_before_ms" => NOW_MS + 600_000,
      "retry_for_primary_ms" => NOW_MS - (NOW_MS % 3_600_000),
      "threads" => {}
    ))

    early = @helper.prepare(now_ms: NOW_MS + 500_000, retry_slot: true, dry_run: true)
    due = @helper.prepare(now_ms: NOW_MS + 700_000, retry_slot: true, dry_run: true)

    assert_equal "retry_not_due", early["reason"]
    assert_equal "ready", due["status"]
  end

  def test_run_finishes_empty_scan_without_leaving_lock
    write_index([])

    result = @helper.run(now_ms: NOW_MS)
    state = YAML.load_file(@state)

    assert_equal "finished", result["status"]
    assert_equal "no_candidates", result["reason"]
    assert_equal NOW_MS, state["last_successful_run_at_ms"]
    assert_equal NOW_MS - TitleMaintenance::WINDOW_MS, state["last_window_start_ms"]
    refute File.exist?(@lock)
  end

  def test_run_returns_candidates_and_keeps_lock_for_model_processing
    write_index([entry("recent-id", NOW_MS - 1_000, "普通任务")])

    result = @helper.run(now_ms: NOW_MS)

    assert_equal "ready", result["status"]
    assert_equal 1, result["candidate_count"]
    assert File.exist?(@lock)
    @helper.fail(run_id: result.fetch("run_id"))
  end

  def test_context_keeps_first_user_and_bounded_recent_messages
    thread_id = "11111111-1111-1111-1111-111111111111"
    write_index([entry(thread_id, NOW_MS - 1_000, "普通任务")])
    write_rollout(thread_id, [
      ["user", "最初主题"],
      *10.times.flat_map { |index| [["user", "用户消息#{index}-#{"x" * 1_000}"], ["assistant", "回复#{index}"]] }
    ])

    result = @helper.prepare(now_ms: NOW_MS, dry_run: true)
    messages = result.dig("candidates", 0, "context", "messages")

    assert_equal "最初主题", messages.first["text"]
    assert_operator messages.length, :<=, TitleMaintenance::CONTEXT_RECENT_MESSAGES + 1
    assert messages.all? { |message| message["text"].length <= TitleMaintenance::CONTEXT_MESSAGE_CHARS }
    assert_equal "回复9", messages.last["text"]
  end

  private

  def entry(id, timestamp_ms, title)
    { "id" => id, "thread_name" => title, "updated_at" => Time.at(timestamp_ms / 1000.0).utc.iso8601(6) }
  end

  def write_index(entries)
    File.write(@index, entries.map(&:to_json).join("\n") + "\n")
  end

  def write_rollout(id, messages)
    path = File.join(@sessions, "rollout-#{id}.jsonl")
    items = [
      { "type" => "session_meta", "payload" => { "cwd" => "/tmp/project" } },
      *messages.map do |role, text|
        { "type" => "response_item", "payload" => { "type" => "message", "role" => role, "content" => [{ "type" => "input_text", "text" => text }] } }
      end
    ]
    File.write(path, items.map(&:to_json).join("\n") + "\n")
  end
end
