#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module TitleEventMaintenance
  THREAD_ID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i.freeze
  WORKER_ENV = "CODEX_TITLE_MAINTENANCE_WORKER"
  EVENT_DELAYS_MS = {
    "session-start" => 30_000,
    "user-prompt" => 20_000,
    "stop" => 90_000
  }.freeze

  module_function

  def now_ms
    (Time.now.to_r * 1000).to_i
  end

  def valid_thread_id?(value)
    THREAD_ID_PATTERN.match?(value.to_s)
  end

  def atomic_write(path, content, mode: 0o600)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    File.open(temp, "w", mode) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temp, path)
  ensure
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
  end

  class BeijingCalendar
    UTC_OFFSET = "+08:00"

    def self.date(time = Time.now)
      time.getlocal(UTC_OFFSET).strftime("%Y-%m-%d")
    end
  end

  class Store
    DEFAULT_ROOT = File.expand_path("~/.codex/title-maintenance")

    attr_reader :root, :queue_path, :state_path, :worker_lock_path

    def initialize(root: ENV.fetch("CODEX_TITLE_EVENT_ROOT", DEFAULT_ROOT))
      @root = root
      @queue_path = File.join(root, "queue.json")
      @queue_lock_path = File.join(root, "queue.lock")
      @state_path = File.join(root, "state.json")
      @state_lock_path = File.join(root, "state.lock")
      @worker_lock_path = File.join(root, "worker.lock")
      FileUtils.mkdir_p(root, mode: 0o700)
    end

    def enqueue(thread_id, source:, now_ms: TitleEventMaintenance.now_ms, force: false, delay_ms: nil)
      raise ArgumentError, "invalid Codex thread id: #{thread_id.inspect}" unless TitleEventMaintenance.valid_thread_id?(thread_id)

      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        queue["revision"] = integer(queue["revision"]) + 1
        current = queue.fetch("threads", {})[thread_id] || {}
        not_before_ms = delay_ms.nil? ? integer(current["not_before_ms"]) : Integer(now_ms) + Integer(delay_ms)
        queue["threads"] ||= {}
        queue["threads"][thread_id] = {
          "queued_at_ms" => [integer(current["queued_at_ms"]), Integer(now_ms)].max,
          "revision" => queue["revision"],
          "sources" => (Array(current["sources"]) + [source.to_s]).uniq.sort,
          "force" => !!current["force"] || !!force,
          "not_before_ms" => [integer(current["not_before_ms"]), not_before_ms].max,
          "attempts" => 0,
          "next_retry_at_ms" => 0,
          "last_error" => nil
        }
        write_json(@queue_path, queue)
        queue["threads"][thread_id]
      end
    end

    # Replace the current queue entry with a fresh, non-immediate event. This is
    # used when the task changes while a title decision is in flight: the old
    # decision must not be applied, and the replacement should wait for a full
    # inactivity window even when the original event was forced.
    def defer_until_idle(thread_id, source:, now_ms: TitleEventMaintenance.now_ms)
      raise ArgumentError, "invalid Codex thread id: #{thread_id.inspect}" unless TitleEventMaintenance.valid_thread_id?(thread_id)

      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        queue["revision"] = integer(queue["revision"]) + 1
        current = queue.fetch("threads", {})[thread_id] || {}
        queue["threads"] ||= {}
        queue["threads"][thread_id] = {
          "queued_at_ms" => Integer(now_ms),
          "revision" => queue["revision"],
          "sources" => (Array(current["sources"]) + [source.to_s]).uniq.sort,
          "force" => false,
          "attempts" => 0,
          "next_retry_at_ms" => 0,
          "last_error" => nil
        }
        write_json(@queue_path, queue)
        queue["threads"][thread_id]
      end
    end

    def snapshot(now_ms:, idle_ms:)
      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        queue.fetch("threads", {}).each_with_object({}) do |(thread_id, entry), result|
          next if integer(entry["next_retry_at_ms"]) > now_ms
          due = if entry["force"]
                  true
                elsif integer(entry["not_before_ms"]).positive?
                  now_ms >= integer(entry["not_before_ms"])
                else
                  now_ms - integer(entry["queued_at_ms"]) >= idle_ms
                end
          next unless due

          result[thread_id] = deep_copy(entry)
        end
      end
    end

    def seconds_until_next(now_ms:, idle_ms:)
      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        waits = queue.fetch("threads", {}).values.map do |entry|
          retry_wait = integer(entry["next_retry_at_ms"]) - now_ms
          idle_wait = if entry["force"]
                        0
                      elsif integer(entry["not_before_ms"]).positive?
                        integer(entry["not_before_ms"]) - now_ms
                      else
                        integer(entry["queued_at_ms"]) + idle_ms - now_ms
                      end
          [retry_wait, idle_wait, 0].max
        end
        waits.empty? ? nil : (waits.min / 1000.0).ceil
      end
    end

    def acknowledge(snapshot)
      return if snapshot.empty?

      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        threads = queue.fetch("threads", {})
        snapshot.each do |thread_id, processed|
          current = threads[thread_id]
          next unless current
          next unless integer(current["revision"]) == integer(processed["revision"])

          threads.delete(thread_id)
        end
        write_json(@queue_path, queue)
      end
    end

    def mark_retry(snapshot, error:, now_ms:, delay_ms:)
      attempts = []
      with_lock(@queue_lock_path) do
        queue = load_json(@queue_path, empty_queue)
        threads = queue.fetch("threads", {})
        snapshot.each do |thread_id, processed|
          current = threads[thread_id]
          next unless current
          next unless integer(current["revision"]) == integer(processed["revision"])

          current["attempts"] = integer(current["attempts"]) + 1
          current["next_retry_at_ms"] = Integer(now_ms) + Integer(delay_ms)
          current["last_error"] = error.to_s[0, 500]
          attempts << current["attempts"]
        end
        write_json(@queue_path, queue)
      end
      attempts.max || 0
    end

    def queue_size
      with_lock(@queue_lock_path) do
        load_json(@queue_path, empty_queue).fetch("threads", {}).length
      end
    end

    def read_state
      with_lock(@state_lock_path) { load_json(@state_path, empty_state) }
    end

    def update_state
      with_lock(@state_lock_path) do
        state = load_json(@state_path, empty_state)
        yield state
        write_json(@state_path, state)
        deep_copy(state)
      end
    end

    def with_worker_lock
      FileUtils.mkdir_p(File.dirname(@worker_lock_path), mode: 0o700)
      File.open(@worker_lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        return false unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.rewind
        file.truncate(0)
        file.write({ "pid" => Process.pid, "started_at_ms" => TitleEventMaintenance.now_ms }.to_json)
        file.flush
        begin
          yield
        ensure
          file.rewind
          file.truncate(0)
          file.flush
        end
        true
      end
    end

    private

    def empty_queue
      { "version" => 1, "revision" => 0, "threads" => {} }
    end

    def empty_state
      {
        "version" => 1,
        "bootstrap_completed" => false,
        "last_startup_warmup_ms" => 0,
        "last_reconcile_date" => nil,
        "last_pr_poll_ms" => 0,
        "prs" => {},
        "last_error_notification" => nil
      }
    end

    def integer(value)
      value.nil? ? 0 : Integer(value)
    rescue ArgumentError, TypeError
      0
    end

    def load_json(path, fallback)
      return deep_copy(fallback) unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : deep_copy(fallback)
    rescue JSON::ParserError, Errno::ENOENT
      deep_copy(fallback)
    end

    def write_json(path, value)
      TitleEventMaintenance.atomic_write(path, JSON.pretty_generate(value) + "\n")
    end

    def with_lock(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
