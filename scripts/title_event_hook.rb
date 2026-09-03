#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "title_event_store"

OWNER_THREAD_ID = ENV["CODEX_TITLE_OWNER_ID"]
LAUNCH_AGENT_LABEL = ENV.fetch("CODEX_TITLE_LAUNCH_AGENT_LABEL", "local.codex-session-title-maintenance")
EVENT_SOURCES = {
  "sessionstart" => "session-start",
  "userpromptsubmit" => "user-prompt",
  "stop" => "stop"
}.freeze

def extract_thread_id(payload)
  values = [payload["thread_id"], payload["threadId"], payload["session_id"], payload["sessionId"]]
  values.each { |value| return value if TitleEventMaintenance.valid_thread_id?(value) }

  transcript = payload["transcript_path"].to_s
  transcript[/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i]
end

def wake_worker(store)
  return if ENV["CODEX_TITLE_EVENT_DISABLE_WAKE"] == "1"

  if File.file?(store.worker_lock_path)
    lock = JSON.parse(File.read(store.worker_lock_path)) rescue {}
    pid = Integer(lock["pid"]) rescue nil
    if pid
      command, = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "command=")
      if command.include?("title_event_worker.rb")
        Process.kill("USR1", pid)
        return
      end
    end
  end

  system(
    "/bin/launchctl",
    "kickstart",
    "gui/#{Process.uid}/#{LAUNCH_AGENT_LABEL}",
    out: File::NULL,
    err: File::NULL
  )
rescue StandardError
  nil
end

exit 0 if ENV[TitleEventMaintenance::WORKER_ENV] == "1"

begin
  raw = STDIN.read
  payload = raw.strip.empty? ? {} : JSON.parse(raw)
  event_name = payload["hook_event_name"] || payload["event"]
  event_source = EVENT_SOURCES[event_name.to_s.downcase]
  exit 0 unless event_source
  thread_id = extract_thread_id(payload)

  if (canary_path = ENV["CODEX_TITLE_CANARY_PATH"])
    exit 0 unless event_source == "stop"
    raise "Stop canary payload did not contain a valid thread id" unless thread_id

    store = TitleEventMaintenance::Store.new
    store.enqueue(thread_id, source: "canary")
    TitleEventMaintenance.atomic_write(
      canary_path,
      JSON.pretty_generate(
        "hook_event_name" => event_name || "Stop",
        "thread_id" => thread_id,
        "observed_at" => Time.now.utc.iso8601,
        "pid" => Process.pid
      ) + "\n"
    )
    exit 0
  end

  exit 0 unless thread_id
  exit 0 if thread_id == OWNER_THREAD_ID

  store = TitleEventMaintenance::Store.new
  store.enqueue(
    thread_id,
    source: event_source,
    delay_ms: TitleEventMaintenance::EVENT_DELAYS_MS.fetch(event_source)
  )
  wake_worker(store)
rescue StandardError => error
  root = ENV.fetch("CODEX_TITLE_EVENT_ROOT", TitleEventMaintenance::Store::DEFAULT_ROOT)
  FileUtils.mkdir_p(root, mode: 0o700)
  File.open(File.join(root, "hook-errors.log"), "a", 0o600) do |file|
    file.puts("#{Time.now.utc.iso8601} #{error.class}: #{error.message}")
  end
end

exit 0
