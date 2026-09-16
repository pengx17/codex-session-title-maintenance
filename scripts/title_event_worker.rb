#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "open3"
require "digest"
require_relative "codex_app_server_client"
require_relative "title_event_store"
require_relative "title_maintenance"
require_relative "title_task_engine"

class TitleEventWorker
  IDLE_MS = 90_000
  RETRY_MS = 600_000
  PR_POLL_MS = 600_000
  STARTUP_WARMUP_COOLDOWN_MS = 1_800_000
  PASS_LIMIT = 8

  def initialize(store: TitleEventMaintenance::Store.new, helper: TitleMaintenance.new,
                 engine: nil, app_client_factory: -> { CodexAppServerClient.new },
                 now: -> { Time.now }, owner_thread_id: ENV["CODEX_TITLE_OWNER_ID"])
    @store, @helper, @now, @owner_thread_id = store, helper, now, owner_thread_id
    @engine = engine || TitleTaskEngine.new(store: TitleTaskStore.new(root: File.join(store.root, "tasks-v1")))
    @app_client_factory = app_client_factory
  end

  def run(allow_outside_hours: false, force_reconcile: false, dry_run: false)
    result = nil
    locked = @store.with_worker_lock { result = run_locked(force_reconcile: force_reconcile, dry_run: dry_run) }
    locked ? result : { "status" => "skipped", "reason" => "worker_already_running" }
  end

  def run_daemon
    locked = @store.with_worker_lock do
      @wake_reader, @wake_writer = IO.pipe
      previous = Signal.trap("USR1") { @wake_writer.write_nonblock(".", exception: false) rescue nil }
      begin
        startup = millis - @store.read_state.fetch("last_startup_warmup_ms", 0).to_i >= STARTUP_WARMUP_COOLDOWN_MS
        loop do
          result = run_locked(force_reconcile: startup, dry_run: false)
          if startup && result["status"] == "finished"
            @store.update_state { |state| state["last_startup_warmup_ms"] = millis }
            startup = false
          end
          puts JSON.generate(result) unless result["reason"] == "no_due_events"
          $stdout.flush
          wait_for_wake(result["status"] == "error" ? 60 : next_wake_seconds)
        end
      ensure
        Signal.trap("USR1", previous)
        @wake_reader.close
        @wake_writer.close
      end
    end
    { "status" => "skipped", "reason" => locked ? "stopped" : "worker_already_running" }
  end

  private

  def run_locked(force_reconcile:, dry_run:)
    now_ms = millis
    date = TitleEventMaintenance::BeijingCalendar.date(@now.call)
    state = @store.read_state
    reconcile = force_reconcile || state["last_reconcile_date"] != date
    snapshot = @store.snapshot(now_ms: now_ms, idle_ms: IDLE_MS)
    # Metadata-only lookup: transcript consumption belongs exclusively to the engine.
    prepared = @helper.prepare(now_ms: now_ms, dry_run: true,
      thread_ids: reconcile ? nil : snapshot.keys, force_thread_ids: snapshot.keys,
      refresh_scope: true, include_context: false)
    raise "candidate lookup unavailable: #{prepared['reason']}" unless prepared["status"] == "ready"
    candidates = prepared.fetch("candidates").reject { |entry| entry["id"] == @owner_thread_id }
    return { "status" => "dry_run", "candidates" => candidates, "queue" => snapshot } if dry_run

    if reconcile
      candidates.each do |candidate|
        id = candidate["id"]
        @store.enqueue(id, source: "reconcile", now_ms: now_ms, force: true) unless @store.event_revision(id)
      end
      @store.update_state { |current| current["last_reconcile_date"] = date }
    end
    if now_ms - state.fetch("last_pr_poll_ms", 0).to_i >= PR_POLL_MS
      @engine.poll_due_ids.each do |id|
        next if id == @owner_thread_id || @store.event_revision(id)
        @store.enqueue(id, source: "pr-status", now_ms: now_ms, force: true)
      end
      @store.update_state do |current|
        current["last_pr_poll_ms"] = now_ms
        current["poll_errors"] = @engine.poll_errors
      end
    end
    snapshot = @store.snapshot(now_ms: now_ms, idle_ms: IDLE_MS)
    return { "status" => "finished", "reason" => "no_due_events" } if snapshot.empty?
    by_id = candidates.each_with_object({}) { |entry, index| index[entry["id"]] = entry }
    missing = snapshot.keys - by_id.keys
    unless missing.empty?
      extra = @helper.prepare(now_ms: now_ms, dry_run: true, thread_ids: missing,
        force_thread_ids: missing, refresh_scope: true, include_context: false)
      extra.fetch("candidates", []).each { |entry| by_id[entry["id"]] = entry }
    end
    outcomes = snapshot.sort_by { |_, entry| [entry.fetch("next_retry_at_ms", 0), entry["revision"]] }.first(PASS_LIMIT).map do |id, event|
      if id == @owner_thread_id
        @store.acknowledge(id => event)
        next { "id" => id, "action" => "excluded" }
      end
      process(id, event, by_id[id])
    end
    { "status" => "finished", "outcomes" => outcomes, "queue_size" => @store.queue_size }
  rescue StandardError => error
    { "status" => "error", "error" => "#{error.class}: #{error.message}" }
  end

  def process(id, event, candidate)
    raise "task missing from session index; event retained" unless candidate
    client = @app_client_factory.call
    client.connect
    original = client.read_thread(id)
    raise "native title pending" if original["name"].to_s.strip.empty?
    document = @engine.advance(id, candidate["rollout_path"])
    if document["excluded"]
      @store.acknowledge(id => event)
      return { "id" => id, "action" => "excluded" }
    end
    unless document["caught_up"]
      return defer(id, event, "reconstructing", delay_ms: 1_000)
    end
    phase = @store.lifecycle(id)
    last_message = document.dig("cursor", "last_message") || {}
    active = if phase && %w[user-prompt stop].include?(phase["source"])
               phase["source"] == "user-prompt"
             else
               last_message["role"] == "user" || (last_message["role"] == "assistant" && !%w[final final_answer].include?(last_message["phase"]))
             end
    active ||= status_type(original["status"]) == "active"
    result = @engine.presentation(id, active_turn: active, refresh_prs: Array(event["sources"]).include?("pr-status"))
    raise result["reason"] unless result["title"]
    live = client.read_thread(id)
    fresh = @engine.fresh?(id, user_only: active && result["status"] != "✅")
    unless @store.event_revision(id) == event["revision"] && live["name"] == original["name"] && fresh
      return defer(id, event, "changed_before_write")
    end
    # Recheck loaded activity immediately before publishing a terminal title.
    if result["status"] == "✅" && status_type(live["status"]) == "active"
      return defer(id, event, "turn_started_before_write")
    end
    title = result.fetch("title")
    action = title == live["name"] ? "keep" : "rename"
    if action == "rename"
      client.set_thread_name(id, title)
    end
    verified = client.read_thread(id)
    raise "app-server title readback mismatch" unless verified["name"] == title
    @helper.lookup(id, expect_title: title, timeout_ms: 5_000)
    @engine.applied(id, title, disposition: action)
    unless @store.event_revision(id) == event["revision"] && @engine.fresh?(id)
      return defer(id, event, "changed_after_write")
    end
    @store.acknowledge(id => event)
    { "id" => id, "action" => action, "title" => title, "reason" => result["reason"] }
  rescue StandardError => error
    begin
      @engine.error(id, error)
    rescue StandardError
      # Preserve a corrupt checkpoint for diagnosis rather than replacing it.
    end
    attempts = @store.mark_retry({ id => event }, error: error.message, now_ms: millis, delay_ms: RETRY_MS)
    notify_failure(error) if attempts >= 2
    { "id" => id, "action" => "error", "error" => error.message }
  ensure
    client.close if client
  end

  def defer(id, event, reason, delay_ms: 20_000)
    # Never replace a newer lifecycle event with a maintenance retry.
    @store.mark_retry({ id => event }, error: reason, now_ms: millis, delay_ms: delay_ms)
    { "id" => id, "action" => "deferred", "reason" => reason }
  end

  def status_type(status)
    status.is_a?(Hash) ? status["type"] : status.to_s
  end

  def notify_failure(error)
    message = error.message.to_s.gsub(/[\r\n]+/, " ")[0, 180]
    fingerprint = Digest::SHA256.hexdigest(message)
    notify = false
    @store.update_state do |state|
      previous = state["last_error_notification"] || {}
      if previous["fingerprint"] != fingerprint || millis - previous.fetch("at_ms", 0) > 21_600_000
        state["last_error_notification"] = { "fingerprint" => fingerprint, "at_ms" => millis }
        notify = true
      end
    end
    Open3.capture3("/usr/bin/osascript", "-e", "display notification #{JSON.generate(message)} with title \"Codex 标题维护失败\"") if notify
  rescue StandardError => notification_error
    warn "notification failed: #{notification_error.class}"
  end

  def millis
    (@now.call.to_r * 1000).to_i
  end

  def next_wake_seconds
    queue_wait = @store.seconds_until_next(now_ms: millis, idle_ms: IDLE_MS)
    poll_wait = [(@store.read_state.fetch("last_pr_poll_ms", 0).to_i + PR_POLL_MS - millis) / 1000.0, 1].max
    [queue_wait || 60, poll_wait, 60].min.clamp(1, 60)
  end

  def wait_for_wake(seconds)
    return unless IO.select([@wake_reader], nil, nil, seconds)
    loop do
      chunk = @wake_reader.read_nonblock(4096, exception: false)
      break if chunk == :wait_readable || chunk.nil?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { force_reconcile: false, dry_run: false, daemon: false }
  OptionParser.new do |opts|
    opts.on("--allow-outside-hours") { options[:allow_outside_hours] = true }
    opts.on("--force-reconcile") { options[:force_reconcile] = true }
    opts.on("--dry-run") { options[:dry_run] = true }
    opts.on("--daemon") { options[:daemon] = true }
  end.parse!(ARGV)
  ENV[TitleEventMaintenance::WORKER_ENV] = "1"
  daemon = options.delete(:daemon)
  result = daemon ? TitleEventWorker.new.run_daemon : TitleEventWorker.new.run(**options)
  puts JSON.generate(result)
  exit(result["status"] == "error" ? 1 : 0)
end
