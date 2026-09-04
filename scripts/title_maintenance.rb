#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "securerandom"
require "set"
require "time"
require "yaml"
require "fileutils"

class TitleMaintenance
  WINDOW_MS = 24 * 60 * 60 * 1000
  LOCK_TTL_MS = 55 * 60 * 1000
  CONTEXT_MESSAGE_CHARS = 800
  CONTEXT_RECENT_MESSAGES = 5
  AUTOMATION_TITLE = "每小时整理近期 Codex Session 标题"

  def initialize(paths = {})
    codex_dir = ENV.fetch("CODEX_TITLE_CODEX_DIR", File.expand_path("~/.codex"))
    @index_path = paths.fetch(:index, ENV.fetch("CODEX_TITLE_INDEX_PATH", File.join(codex_dir, "session_index.jsonl")))
    @state_path = paths.fetch(:state, ENV.fetch("CODEX_TITLE_STATE_PATH", File.join(codex_dir, "memories/codex-thread-title-maintenance.md")))
    @lock_path = paths.fetch(:lock, ENV.fetch("CODEX_TITLE_LOCK_PATH", File.join(codex_dir, "memories/codex-thread-title-maintenance.lock.json")))
    @pinned_path = paths.fetch(:pinned, ENV.fetch("CODEX_TITLE_PINNED_PATH", File.join(codex_dir, "skills/codex-session-title-maintenance/config/pinned-thread-ids.txt")))
    @session_roots = paths.fetch(:session_roots, [File.join(codex_dir, "sessions"), File.join(codex_dir, "archived_sessions")])
    @owner_id = paths.fetch(:owner_id, ENV["CODEX_TITLE_OWNER_ID"])
  end

  def prepare(now_ms:, retry_slot: false, dry_run: false, thread_ids: nil, force_thread_ids: [], force_all: false, refresh_scope: false)
    state = load_state
    if retry_slot
      primary_ms = now_ms - (now_ms % 3_600_000)
      return skipped("no_pending_retry") unless state["retry_pending"]
      return skipped("retry_not_due") if integer(state["retry_not_before_ms"]) > now_ms
      return skipped("retry_belongs_to_another_hour") unless integer(state["retry_for_primary_ms"]) == primary_ms
    end

    lock = load_json(@lock_path)
    if lock && now_ms - integer(lock["started_at_ms"]) < LOCK_TTL_MS
      return skipped("active_lock", "lock" => lock)
    end

    run_id = SecureRandom.uuid
    write_json(@lock_path, { "run_id" => run_id, "started_at_ms" => now_ms, "pid" => Process.pid }) unless dry_run
    window_start_ms = now_ms - WINDOW_MS
    pinned_ids = load_pinned_ids
    rollouts = rollout_map
    threads = state.fetch("threads", {}) || {}
    selected_ids = thread_ids.nil? ? nil : Set.new(thread_ids)
    forced_ids = Set.new(force_thread_ids)

    candidates = latest_index_entries.each_with_object([]) do |entry, selected|
      id = entry.fetch("id")
      title = entry.fetch("thread_name", "")
      updated_at_ms = iso_ms(entry["updated_at"])
      next if selected_ids && !selected_ids.include?(id)
      next if excluded?(id, title)

      pinned = pinned_ids.include?(id)
      recent = updated_at_ms >= window_start_ms
      forced = force_all || forced_ids.include?(id)
      next unless recent || pinned || forced
      next unless forced || refresh_scope || updated_at_ms > integer(threads.dig(id, "updated_at_ms"))

      context = extract_context(rollouts[id])
      next if context["automation_run"]

      selected << {
        "id" => id,
        "title" => title,
        "updated_at" => entry["updated_at"],
        "updated_at_ms" => updated_at_ms,
        "reasons" => [].tap do |reasons|
          reasons << "recent" if recent
          reasons << "pinned" if pinned
          reasons << "forced" if forced
          reasons << "refresh" if refresh_scope
        end,
        "rollout_path" => rollouts[id],
        "context" => context
      }
    end

    {
      "status" => "ready",
      "run_id" => dry_run ? nil : run_id,
      "dry_run" => dry_run,
      "now_ms" => now_ms,
      "window_start_ms" => window_start_ms,
      "candidate_count" => candidates.length,
      "candidates" => candidates.sort_by { |item| -item["updated_at_ms"] }
    }
  rescue StandardError
    clear_lock(run_id) if defined?(run_id) && !dry_run
    raise
  end

  # Scheduled fast path: an empty scan is completed atomically so the caller
  # does not need a second model/tool round trip just to invoke `finish`.
  def run(now_ms:, retry_slot: false, dry_run: false, thread_ids: nil, force_thread_ids: [], force_all: false, refresh_scope: false)
    prepared = prepare(
      now_ms: now_ms,
      retry_slot: retry_slot,
      dry_run: dry_run,
      thread_ids: thread_ids,
      force_thread_ids: force_thread_ids,
      force_all: force_all,
      refresh_scope: refresh_scope
    )
    return prepared unless prepared["status"] == "ready"
    return prepared if dry_run || prepared["candidate_count"].positive?

    finish(
      run_id: prepared.fetch("run_id"),
      now_ms: now_ms,
      window_start_ms: prepared.fetch("window_start_ms")
    )
    {
      "status" => "finished",
      "reason" => "no_candidates",
      "candidate_count" => 0,
      "last_successful_run_at_ms" => now_ms
    }
  end

  def lookup(thread_id, expect_title: nil, after_ms: nil, timeout_ms: 0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) + timeout_ms
    loop do
      entry = latest_index_entries.find { |item| item["id"] == thread_id }
      raise "thread not found in session index: #{thread_id}" unless entry

      title_matches = expect_title.nil? || entry.fetch("thread_name", "") == expect_title
      timestamp_matches = after_ms.nil? || iso_ms(entry["updated_at"]) > after_ms
      if title_matches && timestamp_matches
        return {
          "id" => thread_id,
          "title" => entry.fetch("thread_name", ""),
          "updated_at" => entry["updated_at"],
          "updated_at_ms" => iso_ms(entry["updated_at"])
        }
      end
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) >= deadline

      sleep 0.25
    end
    raise "thread update not visible in session index after #{timeout_ms}ms: #{thread_id}"
  end

  def record(run_id:, thread_id:, updated_at_ms:, disposition:)
    verify_lock!(run_id)
    raise "invalid disposition: #{disposition}" unless %w[kept renamed].include?(disposition)

    state = load_state
    state["threads"] ||= {}
    state["threads"][thread_id] = {
      "updated_at_ms" => Integer(updated_at_ms),
      "disposition" => disposition
    }
    write_yaml(state)
    { "status" => "recorded", "id" => thread_id, "updated_at_ms" => Integer(updated_at_ms), "disposition" => disposition }
  end

  def finish(run_id:, now_ms:, window_start_ms:)
    verify_lock!(run_id)
    state = load_state
    state["last_successful_run_at_ms"] = now_ms
    state["last_window_start_ms"] = window_start_ms
    clear_retry(state)
    write_yaml(state)
    clear_lock(run_id)
    { "status" => "finished", "last_successful_run_at_ms" => now_ms }
  end

  def defer_retry(run_id:, now_ms:)
    verify_lock!(run_id)
    state = load_state
    state["retry_pending"] = true
    state["retry_not_before_ms"] = now_ms + 10 * 60 * 1000
    state["retry_for_primary_ms"] = now_ms - (now_ms % 3_600_000)
    write_yaml(state)
    clear_lock(run_id)
    { "status" => "retry_deferred", "retry_not_before_ms" => state["retry_not_before_ms"] }
  end

  def fail(run_id: nil)
    verify_lock!(run_id) if run_id
    state = load_state
    clear_retry(state)
    write_yaml(state)
    clear_lock(run_id)
    { "status" => "failed_state_cleared" }
  end

  private

  def skipped(reason, extra = {})
    { "status" => "skipped", "reason" => reason }.merge(extra)
  end

  def integer(value)
    value.nil? ? 0 : Integer(value)
  rescue ArgumentError, TypeError
    0
  end

  def iso_ms(value)
    (Time.iso8601(value.to_s).to_r * 1000).to_i
  rescue ArgumentError
    raise "invalid updated_at timestamp: #{value.inspect}"
  end

  def latest_index_entries
    raise "session index missing: #{@index_path}" unless File.file?(@index_path)

    latest = {}
    File.foreach(@index_path) do |line|
      entry = JSON.parse(line)
      next unless entry["id"] && entry["updated_at"]

      previous = latest[entry["id"]]
      latest[entry["id"]] = entry if previous.nil? || iso_ms(entry["updated_at"]) >= iso_ms(previous["updated_at"])
    rescue JSON::ParserError
      next
    end
    latest.values
  end

  def load_state
    state = File.file?(@state_path) ? (YAML.load_file(@state_path) || {}) : {}
    raise "state must be a YAML mapping: #{@state_path}" unless state.is_a?(Hash)

    state["retry_pending"] = false unless state.key?("retry_pending")
    state["threads"] ||= {}
    state
  end

  def write_yaml(state)
    atomic_write(@state_path, YAML.dump(state))
  end

  def load_json(path)
    return nil unless File.file?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  def write_json(path, object)
    atomic_write(path, JSON.pretty_generate(object) + "\n")
  end

  def atomic_write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    File.open(temp, "w", 0o600) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temp, path)
  ensure
    File.delete(temp) if defined?(temp) && File.exist?(temp)
  end

  def load_pinned_ids
    return [] unless File.file?(@pinned_path)

    File.readlines(@pinned_path, chomp: true)
        .map(&:strip)
        .reject { |line| line.empty? || line.start_with?("#") }
  end

  def excluded?(id, title)
    (@owner_id && id == @owner_id) || title == AUTOMATION_TITLE
  end

  def rollout_map
    result = {}
    @session_roots.each do |root|
      next unless Dir.exist?(root)

      Dir.glob(File.join(root, "**", "rollout-*.jsonl")).each do |path|
        id = File.basename(path)[/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl\z/, 1]
        result[id] = path if id
      end
    end
    result
  end

  def extract_context(path)
    return { "cwd" => nil, "repository_url" => nil, "messages" => [], "automation_run" => false } unless path && File.file?(path)

    cwd = nil
    repository_url = nil
    originator = nil
    first_user_message = nil
    recent_messages = []
    mainline_messages = []
    signature_user_texts = []
    File.foreach(path) do |line|
      item = JSON.parse(line)
      payload = item["payload"] || {}
      if item["type"] == "session_meta"
        cwd ||= payload["cwd"]
        originator ||= payload["originator"]
        repository_url ||= payload.dig("git", "repository_url") if payload["git"].is_a?(Hash)
      elsif item["type"] == "response_item" && payload["type"] == "message" && %w[user assistant].include?(payload["role"])
        text = message_text(payload["content"])
        if meaningful_message?(text)
          message = { "role" => payload["role"], "text" => text[0, CONTEXT_MESSAGE_CHARS] }
          if payload["role"] == "user"
            first_user_message ||= message
            mainline_messages << message if mainline_messages.length < 3
            signature_user_texts << message["text"] if signature_user_texts.length < 3
          end
          recent_messages << message
          recent_messages.shift while recent_messages.length > CONTEXT_RECENT_MESSAGES
        end
      end
    rescue JSON::ParserError
      next
    end
    signature = signature_user_texts.join("\n")
    {
      "cwd" => cwd,
      "repository_url" => repository_url,
      "originator" => originator,
      "messages" => [first_user_message, *recent_messages].compact.uniq,
      "mainline_messages" => mainline_messages,
      "recent_messages" => recent_messages,
      "automation_run" => signature.include?("Automation ID: codex-session") || signature.include?(AUTOMATION_TITLE)
    }
  end

  def message_text(content)
    case content
    when String
      content
    when Array
      content.map do |part|
        next unless part.is_a?(Hash)

        part["text"] || part["input_text"] || part["output_text"]
      end.compact.join("\n")
    else
      ""
    end
  end

  def meaningful_message?(text)
    stripped = text.strip
    return false if stripped.empty?

    ignored_prefixes = [
      "<heartbeat>",
      "<recommended_plugins>",
      "# AGENTS.md instructions",
      "<environment_context>",
      "<permissions instructions>"
    ]
    ignored_prefixes.none? { |prefix| stripped.start_with?(prefix) }
  end

  def verify_lock!(run_id)
    lock = load_json(@lock_path)
    raise "maintenance lock missing" unless lock
    raise "maintenance lock belongs to another run" unless lock["run_id"] == run_id
  end

  def clear_lock(run_id = nil)
    return unless File.file?(@lock_path)

    lock = load_json(@lock_path)
    return if run_id && lock && lock["run_id"] != run_id

    File.delete(@lock_path)
  end

  def clear_retry(state)
    state["retry_pending"] = false
    state.delete("retry_not_before_ms")
    state.delete("retry_for_primary_ms")
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    helper = TitleMaintenance.new
    result = case command
           when "prepare", "run"
             options = {
               now_ms: (Time.now.to_r * 1000).to_i,
               retry_slot: false,
               dry_run: false,
               thread_ids: [],
               force_thread_ids: [],
               force_all: false,
               refresh_scope: false
             }
             OptionParser.new do |opts|
               opts.on("--now-ms N", Integer) { |value| options[:now_ms] = value }
               opts.on("--retry") { options[:retry_slot] = true }
               opts.on("--dry-run") { options[:dry_run] = true }
               opts.on("--thread-id ID") { |value| options[:thread_ids] << value }
               opts.on("--force-thread-id ID") { |value| options[:force_thread_ids] << value }
               opts.on("--force-all") { options[:force_all] = true }
               opts.on("--refresh-scope") { options[:refresh_scope] = true }
             end.parse!(ARGV)
             options[:thread_ids] = nil if options[:thread_ids].empty?
             command == "run" ? helper.run(**options) : helper.prepare(**options)
           when "lookup"
             options = {}
             OptionParser.new do |opts|
               opts.on("--thread-id ID") { |value| options[:thread_id] = value }
               opts.on("--expect-title TITLE") { |value| options[:expect_title] = value }
               opts.on("--after-ms N", Integer) { |value| options[:after_ms] = value }
               opts.on("--timeout-ms N", Integer) { |value| options[:timeout_ms] = value }
             end.parse!(ARGV)
             helper.lookup(options.delete(:thread_id) { raise KeyError, "missing --thread-id" }, **options)
           when "record"
             options = {}
             OptionParser.new do |opts|
               opts.on("--run-id ID") { |value| options[:run_id] = value }
               opts.on("--thread-id ID") { |value| options[:thread_id] = value }
               opts.on("--updated-at-ms N", Integer) { |value| options[:updated_at_ms] = value }
               opts.on("--disposition VALUE") { |value| options[:disposition] = value }
             end.parse!(ARGV)
             helper.record(**options)
           when "finish"
             options = { now_ms: (Time.now.to_r * 1000).to_i }
             OptionParser.new do |opts|
               opts.on("--run-id ID") { |value| options[:run_id] = value }
               opts.on("--now-ms N", Integer) { |value| options[:now_ms] = value }
               opts.on("--window-start-ms N", Integer) { |value| options[:window_start_ms] = value }
             end.parse!(ARGV)
             helper.finish(**options)
           when "defer-retry"
             options = { now_ms: (Time.now.to_r * 1000).to_i }
             OptionParser.new do |opts|
               opts.on("--run-id ID") { |value| options[:run_id] = value }
               opts.on("--now-ms N", Integer) { |value| options[:now_ms] = value }
             end.parse!(ARGV)
             helper.defer_retry(**options)
           when "fail"
             options = {}
             OptionParser.new { |opts| opts.on("--run-id ID") { |value| options[:run_id] = value } }.parse!(ARGV)
             helper.fail(**options)
           else
             warn "usage: title_maintenance.rb run|prepare|lookup|record|finish|defer-retry|fail [options]"
             exit 2
           end
    puts JSON.pretty_generate(result)
  rescue KeyError, ArgumentError, RuntimeError => error
    warn JSON.generate("status" => "error", "error" => error.message)
    exit 1
  end
end
