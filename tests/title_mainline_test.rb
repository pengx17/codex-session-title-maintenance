require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/title_event_worker"

class TitleMainlineTest < Minitest::Test
  ID = "11111111-1111-7111-8111-111111111111"

  def test_new_prompt_replaces_old_stop_phase_and_deadline
    Dir.mktmpdir do |dir|
      store = TitleEventMaintenance::Store.new(root: dir)
      store.enqueue(ID, source: "stop", now_ms: 1_000, delay_ms: 90_000)
      old = store.snapshot(now_ms: 100_000, idle_ms: 0)
      store.enqueue(ID, source: "user-prompt", now_ms: 2_000, delay_ms: 20_000)
      store.acknowledge(old)
      current = store.snapshot(now_ms: 22_000, idle_ms: 90_000).fetch(ID)
      assert_equal ["user-prompt"], current["sources"]
    end
  end

  def test_active_followup_reopens_completed_title_even_if_model_keeps_and_pr_is_merged
    candidate = {
      "id" => ID, "title" => "✅ [Codex] 自动标题维护",
      "event_sources" => ["user-prompt"],
      "live_version" => { "status" => { "type" => "active" } },
      "pull_requests" => [{ "state" => "MERGED", "statusEmoji" => "✅" }]
    }
    worker = TitleEventWorker.allocate
    result = worker.send(:normalize_provisional_decisions, [candidate], [{ "id" => ID, "action" => "keep", "title" => nil }]).first
    assert_equal "rename", result["action"]
    assert_equal "🔄 [Codex] 自动标题维护", result["title"]
    candidate["live_version"]["status"]["type"] = "idle"
    result = worker.send(:normalize_provisional_decisions, [candidate], [{ "id" => ID, "action" => "keep", "title" => nil }]).first
    assert_equal "keep", result["action"]
  end

  def test_stop_supersedes_prompt_without_forcing_the_task_back_to_active
    Dir.mktmpdir do |dir|
      store = TitleEventMaintenance::Store.new(root: dir)
      store.enqueue(ID, source: "user-prompt", now_ms: 1_000, delay_ms: 20_000)
      store.enqueue(ID, source: "stop", now_ms: 2_000, delay_ms: 90_000)
      assert_empty store.snapshot(now_ms: 22_000, idle_ms: 0)
      assert_equal ["stop"], store.snapshot(now_ms: 92_000, idle_ms: 0).fetch(ID)["sources"]
    end
  end

  def test_accurate_active_title_can_stay_unchanged
    candidate = {"id" => ID, "title" => "🔄 自动标题维护", "event_sources" => ["user-prompt"], "live_version" => {"status" => {"type" => "active"}}}
    decision = {"id" => ID, "action" => "keep", "title" => nil}
    assert_equal [decision], TitleEventWorker.allocate.send(:normalize_provisional_decisions, [candidate], [decision])
  end

  def test_context_separates_mainline_from_recent_work_and_ignores_heartbeats
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rollout.jsonl")
      texts = ["维护 Codex 标题", "包括 pinned", "用状态 emoji", "<heartbeat>巡检</heartbeat>", *10.times.map { |i| "排查步骤#{i}" }]
      File.write(path, texts.map { |text| {"type" => "response_item", "payload" => {"type" => "message", "role" => "user", "content" => text}}.to_json }.join("\n"))
      context = TitleMaintenance.new.send(:extract_context, path)
      assert_equal texts.first(3), context.fetch("mainline_messages").map { |m| m["text"] }
      assert_equal "排查步骤9", context.fetch("recent_messages").last["text"]
      refute context.fetch("messages").any? { |m| m["text"].include?("<heartbeat>") }
      prompt = TitleModelDecider.new.send(:prompt_for, [{"id" => ID, "context" => context}])
      assert_includes prompt, "mainlineMessages"
      assert_includes prompt, "主线"
    end
  end
end
