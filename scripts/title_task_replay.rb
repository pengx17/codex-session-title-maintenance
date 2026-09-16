#!/usr/bin/env ruby
# frozen_string_literal: true
require "optparse"
require_relative "title_task_engine"
require_relative "title_maintenance"

if $PROGRAM_NAME == __FILE__
  options = { batches: 20 }
  OptionParser.new do |opts|
    opts.banner = "Usage: title_task_replay.rb --thread UUID --root SHADOW_DIRECTORY [--batches N] [--inspect]"
    opts.on("--thread ID") { |v| options[:thread] = v }
    opts.on("--root PATH") { |v| options[:root] = v }
    opts.on("--batches N", Integer) { |v| options[:batches] = v }
    opts.on("--inspect") { options[:inspect] = true }
  end.parse!
  abort "--thread and explicit --root are required" unless options[:thread] && options[:root]
  store = TitleTaskStore.new(root: File.expand_path(options[:root]))
  id = options[:thread]
  if options[:inspect]
    puts JSON.pretty_generate(store.load(id))
    exit
  end
  scan = TitleMaintenance.new.prepare(now_ms: (Time.now.to_r * 1000).to_i, dry_run: true,
    thread_ids: [id], force_thread_ids: [id], include_context: false)
  candidate = scan.fetch("candidates").find { |entry| entry["id"] == id }
  abort "task transcript not found" unless candidate
  engine = TitleTaskEngine.new(store: store)
  options[:batches].times do |index|
    doc = engine.advance(id, candidate["rollout_path"])
    puts JSON.generate("batch" => index + 1, "offset" => doc.dig("cursor", "offset"),
      "source_size" => doc["source_size"], "caught_up" => doc["caught_up"],
      "goal" => doc.dig("task", "goal", "topic"), "requirements" => doc.dig("task", "requirements").transform_values { |r| r["status"] })
    $stdout.flush
    if doc["caught_up"]
      puts JSON.pretty_generate(engine.presentation(id, refresh_prs: true))
      exit
    end
  end
  abort "replay checkpoint saved; transcript still reconstructing"
end
