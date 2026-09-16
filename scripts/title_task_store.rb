# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "title_task_state"

class TitleTaskStore
  class Conflict < StandardError; end
  attr_reader :root

  def initialize(root: File.join(ENV.fetch("CODEX_TITLE_EVENT_ROOT", File.expand_path("~/.codex/title-maintenance")), "tasks-v1"))
    @root = root
    FileUtils.mkdir_p(root, mode: 0o700)
  end

  def load(thread_id)
    file = path(thread_id)
    return { "version" => 1, "revision" => 0, "thread_id" => thread_id, "task" => TitleTaskState.empty,
             "cursor" => nil, "caught_up" => false, "pr_facts" => {}, "last_applied" => nil } unless File.file?(file)

    value = JSON.parse(File.read(file))
    raise Conflict, "unsupported or mismatched task checkpoint" unless value["version"] == 1 && value["thread_id"] == thread_id
    value
  end

  def save(thread_id, document, expected_revision:, event:)
    File.open(path(thread_id) + ".lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      current = load(thread_id)
      raise Conflict, "task checkpoint changed" unless current["revision"] == expected_revision
      value = JSON.parse(JSON.generate(document))
      value["revision"] = expected_revision + 1
      value["updated_at_ms"] = (Time.now.to_r * 1000).to_i
      value["last_transition"] = event
      temporary = path(thread_id) + ".tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(value)); file.flush; file.fsync }
      File.rename(temporary, path(thread_id))
      File.open(File.join(root, "audit.jsonl"), File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.puts JSON.generate("thread_id" => thread_id, "revision" => value["revision"],
                                "at_ms" => value["updated_at_ms"], "event" => event,
                                "cursor" => value.dig("cursor", "offset"), "presentation" => value["presentation"])
      end
      value
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end
  end

  def thread_ids
    Dir.glob(File.join(root, "*.json")).map { |file| File.basename(file, ".json") }
  end

  private

  def path(thread_id)
    raise ArgumentError, "invalid thread id" unless thread_id.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
    File.join(root, "#{thread_id}.json")
  end
end
