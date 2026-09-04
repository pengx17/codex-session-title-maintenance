#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "open3"
require_relative "codex_app_server_client"
require_relative "title_event_store"
require_relative "title_maintenance"
require_relative "title_model_decider"
require_relative "title_pr_resolver"

class TitleEventWorker
  IDLE_MS = 90 * 1000
  RETRY_MS = 10 * 60 * 1000
  PR_POLL_MS = 10 * 60 * 1000
  STARTUP_WARMUP_COOLDOWN_MS = 30 * 60 * 1000
  PR_BOOTSTRAP_VERSION = 2
  MODEL_BATCH_SIZE = 8
  def initialize(
    store: TitleEventMaintenance::Store.new,
    helper: TitleMaintenance.new,
    resolver: TitlePullRequestResolver.new,
    decider: TitleModelDecider.new,
    app_client_factory: -> { CodexAppServerClient.new },
    now: -> { Time.now },
    owner_thread_id: ENV["CODEX_TITLE_OWNER_ID"]
  )
    @store = store
    @helper = helper
    @resolver = resolver
    @decider = decider
    @app_client_factory = app_client_factory
    @now = now
    @owner_thread_id = owner_thread_id
  end

  def run(allow_outside_hours: false, force_reconcile: false, dry_run: false)
    current_time = @now.call
    # Kept as a no-op keyword for compatibility with older recovery commands.
    _allow_outside_hours = allow_outside_hours

    result = nil
    locked = @store.with_worker_lock do
      result = run_locked(current_time, force_reconcile: force_reconcile, dry_run: dry_run)
    end
    return { "status" => "skipped", "reason" => "worker_already_running" } unless locked

    result
  end

  def run_daemon
    result = nil
    locked = @store.with_worker_lock do
      @wake_reader, @wake_writer = IO.pipe
      previous_handler = Signal.trap("USR1") do
        @wake_writer.write_nonblock(".", exception: false)
      rescue IOError, SystemCallError
        nil
      end
      begin
        result = daemon_loop
      ensure
        Signal.trap("USR1", previous_handler)
        @wake_reader.close unless @wake_reader.closed?
        @wake_writer.close unless @wake_writer.closed?
      end
    end
    return { "status" => "skipped", "reason" => "worker_already_running" } unless locked

    result
  end

  private

  def run_locked(current_time, force_reconcile:, dry_run:)
    now_ms = (current_time.to_r * 1000).to_i
    event_state = @store.read_state
    retry_at_ms = integer(event_state["worker_retry_at_ms"])
    if !dry_run && !force_reconcile && retry_at_ms > now_ms
      return { "status" => "finished", "reason" => "retry_pending", "retry_at_ms" => retry_at_ms }
    end

    unless dry_run
      bootstrap_ready = event_state["bootstrap_completed"] && integer(event_state["bootstrap_version"]) == PR_BOOTSTRAP_VERSION
      bootstrap_pr_registry(now_ms) unless bootstrap_ready
      poll_tracked_prs(now_ms)
    end

    date = TitleEventMaintenance::BeijingCalendar.date(current_time)
    event_state = @store.read_state
    reconcile = force_reconcile || event_state["last_reconcile_date"] != date
    snapshot = @store.snapshot(now_ms: now_ms, idle_ms: IDLE_MS)
    if snapshot.empty? && !reconcile
      clear_worker_failure unless dry_run
      return { "status" => "finished", "reason" => "no_due_events", "queue_size" => @store.queue_size }
    end

    selected_ids = reconcile ? nil : snapshot.keys
    # Every explicit event is authoritative even when session_index.jsonl keeps
    # the timestamp from the initial native title. Queue debounce owns event
    # deduplication; the persisted index timestamp must not discard later Stops.
    forced_ids = snapshot.keys
    prepared = @helper.prepare(
      now_ms: now_ms,
      dry_run: dry_run,
      thread_ids: selected_ids,
      force_thread_ids: forced_ids,
      refresh_scope: reconcile
    )
    return prepared.merge("queue_size" => @store.queue_size) unless prepared["status"] == "ready"

    if dry_run
      return prepared.merge("queue_snapshot" => snapshot, "reconcile" => reconcile)
    end

    run_id = prepared.fetch("run_id")
    window_start_ms = prepared.fetch("window_start_ms")
    candidates = prepared.fetch("candidates")
    candidates.reject! { |candidate| @owner_thread_id && candidate["id"] == @owner_thread_id }

    if candidates.empty?
      @helper.finish(run_id: run_id, now_ms: now_ms, window_start_ms: window_start_ms)
      @store.acknowledge(snapshot)
      mark_reconcile_success(date) if reconcile
      clear_worker_failure
      return { "status" => "finished", "reason" => "no_candidates", "queue_size" => @store.queue_size }
    end

    processing_snapshot = ensure_retryable_snapshot(snapshot, candidates, now_ms)
    live_candidates = attach_live_versions(candidates, now_ms)
    enriched = enrich_candidates(live_candidates, processing_snapshot)
    decisions = decisions_for(enriched, processing_snapshot, now_ms)
    outcomes = apply_decisions(run_id, enriched, decisions, now_ms)
    @helper.finish(run_id: run_id, now_ms: now_ms, window_start_ms: window_start_ms)
    applied_ids = outcomes.reject { |outcome| outcome["action"] == "deferred" }.map { |outcome| outcome["id"] }
    persist_pr_tracking(enriched.select { |candidate| applied_ids.include?(candidate["id"]) }, now_ms)
    @store.acknowledge(processing_snapshot)
    mark_reconcile_success(date) if reconcile
    clear_worker_failure
    {
      "status" => "finished",
      "processed" => outcomes.count { |outcome| %w[rename keep].include?(outcome["action"]) },
      "renamed" => outcomes.count { |outcome| outcome["action"] == "rename" },
      "kept" => outcomes.count { |outcome| outcome["action"] == "keep" },
      "deferred" => candidates.length - live_candidates.length + outcomes.count { |outcome| outcome["action"] == "deferred" },
      "queue_size" => @store.queue_size
    }
  rescue StandardError => error
    if defined?(run_id) && run_id
      begin
        @helper.fail(run_id: run_id)
      rescue StandardError => cleanup_error
        warn "failed to clear title-maintenance lock: #{cleanup_error.message}"
      end
    end
    retry_snapshot = defined?(processing_snapshot) && processing_snapshot ? processing_snapshot : snapshot || {}
    queue_attempts = @store.mark_retry(retry_snapshot, error: error.message, now_ms: now_ms, delay_ms: RETRY_MS)
    worker_attempts = record_worker_failure(error, now_ms)
    attempts = [queue_attempts, worker_attempts].max
    notify_failure(error) if attempts >= 2
    {
      "status" => "error",
      "retry_in_seconds" => RETRY_MS / 1000,
      "attempts" => attempts,
      "notified" => attempts >= 2,
      "error" => error.message
    }
  end

  def daemon_loop
    last_result = { "status" => "finished", "reason" => "daemon_started" }
    startup_warmup_pending = startup_warmup_due?(@now.call)
    loop do
      current_time = @now.call
      last_result = run_locked(current_time, force_reconcile: startup_warmup_pending, dry_run: false)
      if startup_warmup_pending && last_result["status"] == "finished" && last_result["reason"] != "retry_pending"
        mark_startup_warmup_success(current_time)
        startup_warmup_pending = false
      end
      sleep_seconds = next_wake_seconds(@now.call)
      wait_for_wake(sleep_seconds)
    end
    last_result
  end

  def wait_for_wake(seconds)
    return sleep(seconds) unless @wake_reader
    return unless IO.select([@wake_reader], nil, nil, seconds)

    loop do
      chunk = @wake_reader.read_nonblock(4_096, exception: false)
      break if chunk == :wait_readable || chunk.nil?
    end
  end

  def next_wake_seconds(current_time)
    now_ms = (current_time.to_r * 1000).to_i
    state = @store.read_state
    retry_at_ms = integer(state["worker_retry_at_ms"])
    return [(retry_at_ms - now_ms) / 1000.0, 1].max if retry_at_ms > now_ms

    waits = []
    queue_wait = @store.seconds_until_next(now_ms: now_ms, idle_ms: IDLE_MS)
    waits << queue_wait if queue_wait
    waits << [((integer(state["last_pr_poll_ms"]) + PR_POLL_MS - now_ms) / 1000.0), 1].max
    [waits.min || 60, 1].max
  end

  def ensure_retryable_snapshot(snapshot, candidates, now_ms)
    combined = snapshot.dup
    candidates.each do |candidate|
      next if combined.key?(candidate["id"])

      @store.enqueue(candidate["id"], source: "reconcile", now_ms: now_ms, force: true)
    end
    current = @store.snapshot(now_ms: now_ms, idle_ms: 0)
    candidates.each_with_object(combined) do |candidate, result|
      entry = current[candidate["id"]] || combined[candidate["id"]]
      result[candidate["id"]] = entry if entry
    end
  end

  def enrich_candidates(candidates, snapshot)
    tracked = @store.read_state.fetch("prs", {})
    candidates.map do |candidate|
      refs = @resolver.refs_for(candidate)
      if refs.empty?
        refs = Array(tracked[candidate["id"]]).map do |entry|
          { "repo" => entry["repo"], "number" => entry["number"] }
        end
      end
      metadata = refs.map { |ref| @resolver.fetch(ref) }
      candidate.merge(
        "pull_requests" => metadata,
        "event_sources" => Array(snapshot.dig(candidate["id"], "sources"))
      )
    end
  end

  def attach_live_versions(candidates, now_ms)
    return [] if candidates.empty?

    client = @app_client_factory.call
    client.connect
    candidates.each_with_object([]) do |candidate, result|
      live = client.read_thread(candidate["id"])
      live_title = live["name"].to_s.strip
      if live_title.empty?
        @store.defer_until_idle(candidate["id"], source: "native-title-pending", now_ms: now_ms)
        next
      end

      result << candidate.merge(
        "title" => live_title,
        "live_version" => live_thread_version(live)
      )
    end
  ensure
    client.close if client
  end

  def decisions_for(candidates, snapshot, now_ms)
    deterministic = []
    semantic = []
    candidates.each do |candidate|
      decision = deterministic_pr_decision(candidate, snapshot[candidate["id"]])
      decision ? deterministic << decision : semantic << candidate
    end

    semantic_decisions = semantic.each_slice(MODEL_BATCH_SIZE).flat_map do |batch|
      resilient_semantic_decisions(batch, now_ms)
    end
    by_id = (deterministic + semantic_decisions).each_with_object({}) { |decision, result| result[decision["id"]] = decision }
    decisions = candidates.map { |candidate| by_id.fetch(candidate["id"]) }
    normalize_provisional_decisions(candidates, decisions)
  end

  def normalize_provisional_decisions(candidates, decisions)
    candidates_by_id = candidates.each_with_object({}) { |candidate, result| result[candidate["id"]] = candidate }
    decisions.map do |decision|
      candidate = candidates_by_id.fetch(decision["id"])
      next decision unless provisional_candidate?(candidate)
      next decision unless %w[keep rename].include?(decision["action"])
      # A keep decision can preserve the topic, but cannot freeze a terminal status
      # while a fresh user turn is demonstrably active (even after a PR merged).
      title = decision["action"] == "keep" ? candidate["title"] : decision["title"]

      current_status = TitleModelDecider::STATUS_EMOJIS.find { |emoji| title.to_s.start_with?(emoji) }
      next decision unless current_status && current_status != "🔄"

      decision.merge("action" => "rename", "title" => "🔄#{title[current_status.length..-1]}")
    end
  end

  def resilient_semantic_decisions(batch, now_ms)
    @decider.decide(batch)
  rescue TitleModelDecider::InvalidDecisionError => error
    if batch.length > 1
      midpoint = batch.length / 2
      return resilient_semantic_decisions(batch.first(midpoint), now_ms) +
        resilient_semantic_decisions(batch.drop(midpoint), now_ms)
    end

    candidate = batch.first
    warn "Terra decision deferred #{candidate['id']}: #{error.message}"
    @store.defer_until_idle(candidate["id"], source: "invalid-model-decision", now_ms: now_ms)
    [{ "id" => candidate["id"], "action" => "deferred", "title" => nil, "reason" => error.message }]
  end

  def deterministic_pr_decision(candidate, event_entry)
    sources = Array(event_entry && event_entry["sources"])
    return nil if sources.empty? || sources.any? { |source| source != "pr-status" }
    status = aggregate_pr_status(candidate["pull_requests"])
    return nil unless status
    return nil unless @decider.valid_title?(candidate["title"])

    current_status = TitleModelDecider::STATUS_EMOJIS.find { |emoji| candidate["title"].start_with?(emoji) }
    new_title = status + candidate["title"][current_status.length..-1]
    if new_title == candidate["title"]
      { "id" => candidate["id"], "action" => "keep", "title" => nil, "reason" => "PR metadata changed without changing the title status class" }
    else
      { "id" => candidate["id"], "action" => "rename", "title" => new_title, "reason" => "PR status changed" }
    end
  end

  def apply_decisions(run_id, candidates, decisions, now_ms)
    return [] if decisions.empty?

    candidate_by_id = candidates.each_with_object({}) { |candidate, result| result[candidate["id"]] = candidate }
    client = @app_client_factory.call
    client.connect

    decisions.map do |decision|
      candidate = candidate_by_id.fetch(decision["id"])
      next decision if decision["action"] == "deferred"

      live = client.read_thread(candidate["id"])
      unless compatible_live_version?(candidate, live)
        @store.defer_until_idle(candidate["id"], source: "changed-during-decision", now_ms: now_ms)
        next decision.merge("action" => "deferred", "title" => nil, "reason" => "task changed while title decision was in flight")
      end

      if decision["action"] == "keep" || decision["title"] == candidate["title"]
        @helper.record(
          run_id: run_id,
          thread_id: candidate["id"],
          updated_at_ms: candidate["updated_at_ms"],
          disposition: "kept"
        )
        next decision.merge("action" => "keep", "title" => nil)
      end

      client.set_thread_name(candidate["id"], decision.fetch("title"))
      visible = @helper.lookup(
        candidate["id"],
        expect_title: decision["title"],
        after_ms: candidate["updated_at_ms"],
        timeout_ms: 5_000
      )
      @helper.record(
        run_id: run_id,
        thread_id: candidate["id"],
        updated_at_ms: visible.fetch("updated_at_ms"),
        disposition: "renamed"
      )
      decision.merge("action" => "rename")
    end
  ensure
    client.close if client
  end

  def live_thread_version(thread)
    {
      "name" => thread["name"].to_s,
      "updatedAt" => thread["updatedAt"],
      "status" => thread["status"]
    }
  end

  def compatible_live_version?(candidate, live)
    return live_thread_version(live) == candidate["live_version"] unless provisional_candidate?(candidate)

    original = candidate.fetch("live_version")
    live["name"].to_s == original["name"].to_s &&
      thread_status_type(live["status"]) == "active" &&
      thread_status_type(original["status"]) == "active"
  end

  def provisional_candidate?(candidate)
    sources = Array(candidate["event_sources"])
    sources.include?("user-prompt") && !sources.include?("stop") &&
      thread_status_type(candidate.dig("live_version", "status")) == "active"
  end

  def thread_status_type(status)
    status.is_a?(Hash) ? status["type"].to_s : status.to_s
  end

  def startup_warmup_due?(current_time)
    now_ms = (current_time.to_r * 1000).to_i
    last_ms = integer(@store.read_state["last_startup_warmup_ms"])
    now_ms - last_ms >= STARTUP_WARMUP_COOLDOWN_MS
  end

  def mark_startup_warmup_success(current_time)
    now_ms = (current_time.to_r * 1000).to_i
    @store.update_state { |state| state["last_startup_warmup_ms"] = now_ms }
  end

  def bootstrap_pr_registry(now_ms)
    scan = @helper.prepare(now_ms: now_ms, dry_run: true, refresh_scope: true)
    unless scan["status"] == "ready"
      raise "PR bootstrap scan unavailable: #{scan["status"]} #{scan["reason"]}".strip
    end
    tracked = {}
    scan.fetch("candidates", []).each do |candidate|
      refs = @resolver.refs_for(candidate)
      next if refs.empty?

      metadata = refs.map { |ref| @resolver.fetch(ref) }
      active = metadata.reject { |pr| terminal_pr?(pr) }
      tracked[candidate["id"]] = tracking_entries(active, now_ms) unless active.empty?
      current_status = TitleModelDecider::STATUS_EMOJIS.find { |emoji| candidate["title"].start_with?(emoji) }
      status = aggregate_pr_status(metadata)
      if status && current_status && current_status != status
        @store.enqueue(candidate["id"], source: "pr-status", now_ms: now_ms, force: true)
      end
    rescue StandardError => error
      warn "PR bootstrap skipped #{candidate["id"]}: #{error.message}"
    end
    @store.update_state do |state|
      state["prs"] = state.fetch("prs", {}).merge(tracked)
      state["bootstrap_completed"] = true
      state["bootstrap_version"] = PR_BOOTSTRAP_VERSION
      state["last_pr_poll_ms"] = now_ms
    end
  end

  def poll_tracked_prs(now_ms)
    state = @store.read_state
    return if now_ms - integer(state["last_pr_poll_ms"]) < PR_POLL_MS

    updates = {}
    state.fetch("prs", {}).each do |thread_id, entries|
      next if @owner_thread_id && thread_id == @owner_thread_id

      refreshed = Array(entries).map do |old|
        metadata = @resolver.fetch("repo" => old.fetch("repo"), "number" => old.fetch("number"))
        if old["fingerprint"] && old["fingerprint"] != metadata["fingerprint"]
          source = old["title"] != metadata["title"] ? "pr-content" : "pr-status"
          @store.enqueue(thread_id, source: source, now_ms: now_ms, force: true)
        end
        tracking_entry(metadata, now_ms)
      end
      updates[thread_id] = refreshed
    rescue StandardError => error
      warn "PR poll skipped #{thread_id}: #{error.message}"
    end
    @store.update_state do |current|
      current["prs"] = current.fetch("prs", {}).merge(updates)
      current["last_pr_poll_ms"] = now_ms
    end
  end

  def persist_pr_tracking(candidates, now_ms)
    @store.update_state do |state|
      state["prs"] ||= {}
      candidates.each do |candidate|
        metadata = candidate.fetch("pull_requests", [])
        active = metadata.reject { |pr| terminal_pr?(pr) }
        if metadata.empty?
          state["prs"].delete(candidate["id"]) unless candidate["title"].match?(/(?:\bPR\b|pull request|合并请求)/i)
        elsif active.empty?
          state["prs"].delete(candidate["id"])
        else
          state["prs"][candidate["id"]] = tracking_entries(active, now_ms)
        end
      end
    end
  end

  def tracking_entries(metadata, now_ms)
    metadata.map { |pr| tracking_entry(pr, now_ms) }
  end

  def tracking_entry(pr, now_ms)
    {
      "repo" => pr["repo"],
      "number" => pr["number"],
      "url" => pr["url"],
      "title" => pr["title"],
      "state" => pr["state"],
      "isDraft" => pr["isDraft"],
      "statusEmoji" => pr["statusEmoji"],
      "fingerprint" => pr["fingerprint"],
      "last_checked_ms" => now_ms
    }
  end

  def mark_reconcile_success(date)
    @store.update_state { |state| state["last_reconcile_date"] = date }
  end

  def terminal_pr?(pr)
    pr["mergedAt"] || %w[MERGED CLOSED].include?(pr["state"].to_s.upcase)
  end

  def aggregate_pr_status(metadata)
    statuses = Array(metadata).map { |pr| pr["statusEmoji"] }.compact.uniq
    return nil if statuses.empty?
    return statuses.first if statuses.length == 1

    ["⚠️", "🔄", "🟡", "⛔", "✅"].find { |status| statuses.include?(status) }
  end

  def record_worker_failure(error, now_ms)
    attempts = 0
    @store.update_state do |state|
      attempts = integer(state["worker_retry_attempts"]) + 1
      state["worker_retry_attempts"] = attempts
      state["worker_retry_at_ms"] = now_ms + RETRY_MS
      state["worker_last_error"] = error.message.to_s[0, 500]
    end
    attempts
  end

  def clear_worker_failure
    @store.update_state do |state|
      state.delete("worker_retry_attempts")
      state.delete("worker_retry_at_ms")
      state.delete("worker_last_error")
    end
  end

  def notify_failure(error)
    message = error.message.gsub(/[\r\n]+/, " ")[0, 180]
    fingerprint = Digest::SHA256.hexdigest(message)
    should_notify = false
    @store.update_state do |state|
      previous = state["last_error_notification"] || {}
      if previous["fingerprint"] != fingerprint || TitleEventMaintenance.now_ms - integer(previous["at_ms"]) > 6 * 60 * 60 * 1000
        should_notify = true
        state["last_error_notification"] = { "fingerprint" => fingerprint, "at_ms" => TitleEventMaintenance.now_ms }
      end
    end
    return unless should_notify

    escaped = message.gsub("\\", "\\\\").gsub('"', '\\"')
    script = "display notification \"#{escaped}\" with title \"Codex 标题维护失败\""
    Open3.capture3("/usr/bin/osascript", "-e", script)
  rescue StandardError => notification_error
    warn "failed to notify title maintenance error: #{notification_error.message}"
  end

  def integer(value)
    value.nil? ? 0 : Integer(value)
  rescue ArgumentError, TypeError
    0
  end
end

if $PROGRAM_NAME == __FILE__
  options = { allow_outside_hours: false, force_reconcile: false, dry_run: false, daemon: false }
  OptionParser.new do |opts|
    opts.on("--allow-outside-hours") { options[:allow_outside_hours] = true }
    opts.on("--force-reconcile") { options[:force_reconcile] = true }
    opts.on("--dry-run") { options[:dry_run] = true }
    opts.on("--daemon") { options[:daemon] = true }
  end.parse!(ARGV)

  ENV[TitleEventMaintenance::WORKER_ENV] = "1"
  daemon = options.delete(:daemon)
  result = daemon ? TitleEventWorker.new.run_daemon : TitleEventWorker.new.run(**options)
  puts JSON.generate(result) unless result["status"] == "finished" && result["reason"] == "no_due_events"
  exit(result["status"] == "error" && result["notified"] ? 1 : 0)
end
