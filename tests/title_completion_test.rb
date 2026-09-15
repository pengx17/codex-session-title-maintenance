# frozen_string_literal: true
require "minitest/autorun"
require_relative "../scripts/title_event_worker"

class TitleCompletionTest < Minitest::Test
  def normalize(text, prs = [], action = "keep")
    candidate = { "id" => "one", "title" => "✅ 已修复", "pull_requests" => prs,
                  "context" => { "recent_messages" => [{ "role" => "assistant", "text" => text }] } }
    decision = { "id" => "one", "action" => action, "title" => action == "keep" ? nil : "✅ 已修复" }
    TitleEventWorker.allocate.send(:normalize_completion_decisions, [candidate], [decision]).first
  end

  def test_open_pr_cannot_keep_or_generate_completed_title
    %w[keep rename].each do |action|
      result = normalize("代码完成", [{ "state" => "OPEN", "statusEmoji" => "🟡" }], action)
      assert_equal "🟡 已修复", result["title"]
      assert_equal "rename", result["action"]
    end
  end

  def test_merged_but_unaccepted_is_waiting
    result = normalize("PR 已合并。未部署，未做线上验收。", [{ "state" => "MERGED", "statusEmoji" => "✅" }])
    assert_equal "⏸️ 已修复", result["title"]
  end

  def test_completed_acceptance_remains_completed
    assert_equal "keep", normalize("已合并、部署并完成真实验收。")["action"]
  end

  def test_merge_event_requires_semantic_task_assessment
    worker = TitleEventWorker.allocate
    candidate = { "title" => "🟡 等待合并", "pull_requests" => [{ "statusEmoji" => "✅" }] }
    assert_nil worker.send(:deterministic_pr_decision, candidate, { "sources" => ["pr-status"] })
  end
end

