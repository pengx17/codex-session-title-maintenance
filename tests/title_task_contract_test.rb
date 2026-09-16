# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/title_task_engine"

class TitleTaskContractTest < Minitest::Test
  ID = "11111111-1111-7111-8111-111111111111"

  def setup
    @dir = Dir.mktmpdir("title-contract-")
    @path = File.join(@dir, "transcript.jsonl")
    @store = TitleTaskStore.new(root: File.join(@dir, "tasks"))
    @reader = TitleTranscript.new
    @reducer = TitleTaskState.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def record(text, role: "user", phase: nil)
    JSON.generate("type" => "response_item", "payload" => {
      "type" => "message", "role" => role, "phase" => phase,
      "content" => [{ "text" => text }]
    }) + "\n"
  end

  def msg(id, text, role: "user", phase: nil)
    { "id" => id, "text" => text, "role" => role, "phase" => phase }
  end

  def cite(id, quote)
    [{ "message_id" => id, "quote" => quote }]
  end

  def proposal(action: "retain", topic: "", evidence: [], requirements: [], prs: [], progress: nil)
    { "goal" => { "action" => action, "topic" => topic, "project" => "", "evidence" => evidence },
      "requirements" => requirements, "pull_requests" => prs, "progress" => progress }
  end

  def requirement(id, kind, status, evidence, description = id)
    { "id" => id, "description" => description, "kind" => kind, "status" => status, "evidence" => evidence }
  end

  def initial_state
    @reducer.apply(TitleTaskState.empty,
      proposal(action: "start", topic: "交付功能", evidence: cite("u", "交付功能")),
      [msg("u", "交付功能并验收")])
  end

  def test_evidence_must_exist_and_match_exactly
    [cite("missing", "交付功能"), cite("u", "已经验收")].each do |evidence|
      assert_raises(TitleTaskState::InvalidUpdate) do
        @reducer.apply(TitleTaskState.empty,
          proposal(action: "start", topic: "交付功能", evidence: evidence), [msg("u", "交付功能")])
      end
    end
  end

  def test_omitted_requirements_survive_later_updates_and_merge_does_not_satisfy_acceptance
    state = initial_state
    state = @reducer.apply(state, proposal(
      requirements: [requirement("acceptance", "acceptance", "open", cite("u", "验收"))],
      prs: [{ "repo" => "org/repo", "number" => 42, "relation" => "current", "evidence" => cite("a", "PR #42") }]),
      [msg("u", "验收"), msg("a", "PR #42", role: "assistant")])
    state = @reducer.apply(state, proposal(requirements: [
      requirement("outcome", "outcome", "satisfied", cite("a", "实现完成"), "交付功能")]),
      [msg("a", "实现完成", role: "assistant", phase: "final")])
    result = @reducer.present(state, pr_facts: { "org/repo#42" => { "state" => "MERGED" } }, caught_up: true)
    assert_equal "open", state.dig("requirements", "acceptance", "status")
    assert_includes result["pending_requirements"], "acceptance"
    refute_equal "✅", result["status"]
  end

  def test_commentary_cannot_complete_outcome_and_assistant_cannot_waive
    state = initial_state
    %w[satisfied waived].each do |status|
      assert_raises(TitleTaskState::InvalidUpdate) do
        @reducer.apply(state, proposal(requirements: [requirement("outcome", "outcome", status,
          cite("a", "已完成"), "交付功能")]), [msg("a", "已完成", role: "assistant", phase: "commentary")])
      end
    end
    assert_equal "open", state.dig("requirements", "outcome", "status")
  end

  def test_topic_replacement_requires_user_and_archives_prior_requirements
    state = initial_state
    replacement = proposal(action: "replace", topic: "新目标", evidence: cite("next", "新目标"))
    assert_raises(TitleTaskState::InvalidUpdate) do
      @reducer.apply(state, replacement, [msg("next", "新目标", role: "assistant")])
    end
    newer = @reducer.apply(state, replacement, [msg("next", "新目标")])
    assert_equal "新目标", newer.dig("goal", "topic")
    assert_equal "交付功能", newer.dig("past_goals", 0, "goal", "topic")
    assert_equal "交付功能", state.dig("goal", "topic")
    assert_equal ["outcome"], newer["requirements"].keys
  end

  def test_partial_line_is_never_consumed_then_is_replayed_after_completion
    first = record("第一条")
    second = record("第二条")
    File.binwrite(@path, first + second[0...-1])
    batch = @reader.read(@path)
    assert_equal ["第一条"], batch["messages"].map { |m| m["text"] }
    assert_equal first.bytesize, batch.dig("cursor", "offset")
    assert batch["partial_line"]
    refute batch["caught_up"]
    File.open(@path, "ab") { |file| file.write("\n") }
    rest = @reader.read(@path, cursor: batch["cursor"])
    assert_equal ["第二条"], rest["messages"].map { |m| m["text"] }
    assert rest["caught_up"]
  end

  def test_large_unicode_message_is_consumed_without_gaps_or_duplicate_segments
    body = "长消息🙂" * 5_001
    File.binwrite(@path, record(body))
    cursor = nil
    messages = []
    20.times do
      batch = @reader.read(@path, cursor: cursor, max_messages: 1)
      messages.concat(batch["messages"])
      cursor = batch["cursor"]
      break if batch["caught_up"]
    end
    assert_equal body, messages.map { |m| m["text"] }.join
    assert_equal messages.length, messages.map { |m| m["id"] }.uniq.length
    assert_equal File.size(@path), cursor["offset"]
    assert_equal 0, cursor["segment"]
  end

  def test_cursor_rejects_replacement_and_truncation
    File.write(@path, record("original"))
    cursor = @reader.read(@path)["cursor"]
    File.write(@path, record("replaced"))
    assert_raises(TitleTranscript::SourceChanged) { @reader.read(@path, cursor: cursor) }
    File.write(@path, "")
    assert_raises(TitleTranscript::SourceChanged) { @reader.read(@path, cursor: cursor) }
  end

  def test_complete_corrupt_record_is_not_silently_skipped
    File.write(@path, record("交付功能") + "{broken}\n" + record("已经完成"))
    assert_raises(TitleTranscript::SourceChanged) { @reader.read(@path) }
  end

  def test_transcript_batch_boundary_keeps_middle_messages_across_restart
    File.write(@path, (0...103).map { |index| record("需求 #{index}") }.join)
    first = @reader.read(@path)
    refute first["caught_up"]
    assert_equal 80, first["messages"].length
    # Recreate the reader and serialize the cursor exactly as a restart does.
    second = TitleTranscript.new.read(@path, cursor: JSON.parse(JSON.generate(first["cursor"])))
    assert second["caught_up"]
    assert_equal (0...103).map { |index| "需求 #{index}" },
      (first["messages"] + second["messages"]).map { |message| message["text"] }
  end

  def test_unprocessed_transcript_never_has_a_presentable_title
    result = @reducer.present(initial_state, pr_facts: {}, caught_up: false)
    assert_nil result["title"]
    assert_equal "reconstructing", result["status"]
  end

  def test_ongoing_monitoring_is_not_presented_as_completed_setup
    state = initial_state
    state = @reducer.apply(state, proposal(requirements: [
      requirement("outcome", "outcome", "satisfied", cite("a", "设置完成"), "交付功能")],
      progress: { "kind" => "monitoring", "basis" => "task", "evidence" => cite("u", "继续监控") }),
      [msg("a", "设置完成", role: "assistant", phase: "final"), msg("u", "继续监控")])
    assert_equal "⏱️", @reducer.present(state, pr_facts: {}, caught_up: true)["status"]
  end

  def test_pr_association_cannot_claim_a_different_repository_from_url_evidence
    state = initial_state
    assert_raises(TitleTaskState::InvalidUpdate) do
      @reducer.apply(state, proposal(prs: [{ "repo" => "wrong/repo", "number" => 42,
        "relation" => "current", "evidence" => cite("a", "https://github.com/right/repo/pull/42") }]),
        [msg("a", "https://github.com/right/repo/pull/42", role: "assistant", phase: "final")])
    end
  end

  def test_store_rejects_stale_revision_without_losing_first_commit
    old = @store.load(ID)
    saved = @store.save(ID, old.merge("last_error" => "first"), expected_revision: 0, event: { "kind" => "test" })
    assert_raises(TitleTaskStore::Conflict) do
      @store.save(ID, old.merge("last_error" => "stale"), expected_revision: 0, event: {})
    end
    assert_equal saved, @store.load(ID)
  end

  def model(&block)
    Object.new.tap { |value| value.define_singleton_method(:update, &block) }
  end

  def test_model_failure_does_not_commit_cursor_or_partial_state
    File.write(@path, record("交付功能"))
    before = @store.load(ID)
    engine = TitleTaskEngine.new(store: @store, model: model { |**_| raise "provider unavailable" })
    assert_raises(RuntimeError) { engine.advance(ID, @path) }
    assert_equal before, @store.load(ID)
    assert_empty @store.thread_ids
  end

  def test_invalid_update_retries_with_feedback_but_never_commits_invalid_state
    File.write(@path, record("交付功能"))
    calls = []
    bad = proposal(action: "start", topic: "交付功能", evidence: cite("invented", "交付功能"))
    engine = TitleTaskEngine.new(store: @store, model: model { |**args| calls << args; bad })
    assert_raises(TitleTaskState::InvalidUpdate) { engine.advance(ID, @path) }
    assert_equal 2, calls.length
    assert_nil calls.first[:validation_error]
    assert_match(/evidence/, calls.last[:validation_error])
    assert_nil @store.load(ID)["cursor"]
  end

  def test_new_message_during_model_is_not_falsely_fresh
    File.write(@path, record("交付功能"))
    path = @path
    update = method(:proposal)
    next_record = record("现在增加验收")
    engine = TitleTaskEngine.new(store: @store, model: model do |**args|
      File.open(path, "ab") { |file| file.write(next_record) }
      message = args[:messages].first
      update.call(action: "start", topic: "交付功能", evidence: [{ "message_id" => message["id"], "quote" => "交付功能" }])
    end)
    document = engine.advance(ID, @path)
    assert document["caught_up"] # Snapshot boundary was caught up; freshness must independently reject it.
    refute engine.fresh?(ID)
    assert_operator document.dig("cursor", "offset"), :<, File.size(@path)
  end

  def test_changed_source_during_model_does_not_commit_interpretation
    File.write(@path, record("交付功能"))
    path = @path
    changed = record("替换后的目标")
    update = method(:proposal)
    engine = TitleTaskEngine.new(store: @store, model: model do |**args|
      File.write(path, changed)
      update.call(action: "start", topic: "交付功能", evidence: [{ "message_id" => args[:messages].first["id"], "quote" => "交付功能" }])
    end)
    assert_raises(TitleTranscript::SourceChanged) { engine.advance(ID, @path) }
    assert_nil @store.load(ID)["cursor"]
    assert_nil @store.load(ID).dig("task", "goal")
  end
end
