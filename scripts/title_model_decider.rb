#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"

class TitleModelDecider
  class InvalidDecisionError < StandardError; end

  STATUS_EMOJIS = ["🔄", "🟡", "⚠️", "⏸️", "✅", "⛔", "⏱️"].freeze
  DEFAULT_SCHEMA = File.expand_path("../config/title-decisions.schema.json", __dir__)

  def self.default_codex
    candidates = [
      ENV["CODEX_TITLE_CODEX_BIN"],
      File.expand_path("~/.vite-plus/bin/codex"),
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "codex") }
    ].flatten.compact
    candidates.find { |path| File.file?(path) && File.executable?(path) } || "codex"
  end

  def initialize(
    codex_bin: self.class.default_codex,
    model: ENV.fetch("CODEX_TITLE_MODEL", "gpt-5.6-terra"),
    effort: ENV.fetch("CODEX_TITLE_REASONING_EFFORT", "high"),
    schema_path: ENV.fetch("CODEX_TITLE_SCHEMA_PATH", DEFAULT_SCHEMA),
    timeout_seconds: Integer(ENV.fetch("CODEX_TITLE_MODEL_TIMEOUT_SECONDS", "180")),
    working_directory: ENV.fetch("CODEX_TITLE_MODEL_CWD", Dir.home)
  )
    @codex_bin = codex_bin
    @model = model
    @effort = effort
    @schema_path = schema_path
    @timeout_seconds = timeout_seconds
    @working_directory = working_directory
  end

  def decide(candidates)
    return [] if candidates.empty?

    Dir.mktmpdir("codex-title-model") do |dir|
      output_path = File.join(dir, "decisions.json")
      command = [
        @codex_bin,
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--model",
        @model,
        "-c",
        "model_reasoning_effort=\"#{@effort}\"",
        "--output-schema",
        @schema_path,
        "--output-last-message",
        output_path,
        "--color",
        "never",
        "-"
      ]
      stdout, stderr, status = run(command, prompt_for(candidates))
      unless status.success? && File.file?(output_path)
        detail = [stderr, stdout].map(&:strip).reject(&:empty?).join("\n")[0, 2_000]
        raise "Terra title decision failed (exit #{status.exitstatus}): #{detail}"
      end

      parsed = JSON.parse(File.read(output_path))
      validate_decisions(parsed.fetch("decisions"), candidates)
    end
  rescue JSON::ParserError, KeyError => error
    raise InvalidDecisionError, "invalid Terra title decision output: #{error.message}"
  end

  def valid_title?(title)
    return false unless title.is_a?(String)
    return false if title.length > 100

    prefix = STATUS_EMOJIS.find { |emoji| title.start_with?(emoji) }
    return false unless prefix

    rest = title[prefix.length..-1].to_s
    return false unless rest.start_with?(" ") && rest.strip.length >= 2
    return false if STATUS_EMOJIS.any? { |emoji| rest.include?(emoji) }

    true
  end

  private

  def prompt_for(candidates)
    payload = candidates.map do |candidate|
      {
        "id" => candidate["id"],
        "currentTitle" => candidate["title"],
        "cwd" => candidate.dig("context", "cwd"),
        "messages" => Array(candidate.dig("context", "messages")),
        "eventSources" => Array(candidate["event_sources"]),
        "threadStatus" => candidate.dig("live_version", "status"),
        "pullRequests" => Array(candidate["pull_requests"]).map do |pr|
          pr.reject { |key, _| key == "statusCheckRollup" || key == "fingerprint" }
        end
      }
    end
    <<~PROMPT
      维护 Codex session 标题。只根据下面提供的上下文返回结构化 decisions，不调用工具，也不要补充说明。

      标题格式：状态 emoji + 可选稳定标签 + 简洁中文主题。状态 emoji 必须是首字符，并且标题中不得再有装饰 emoji。
      状态仅用：🔄 实现中或 Draft；🟡 open 非 Draft、CI、review 或 merge-ready；⚠️ 明确 blocker 或失败门禁；⏸️ 等待外部、用户或验收；✅ 已完成或 merged；⛔ closed 未合并；⏱️ 周期巡检。
      idle 不等于完成。实时 pullRequests metadata 高于历史对话；其 statusEmoji 应作为 PR session 的首字符。
      eventSources 包含 user-prompt 且不包含 stop 时，这是长任务开始后的快速标题阶段：标题应反映最新用户目标，非 PR 标题只能使用 🔄，不得宣称完成或等待。后续 stop 事件会用完整结果校正状态。
      只有当前标题过泛、失真、缺少关键项目/PR/主题或状态变化时才 rename，否则 keep。
      保留稳定项目标签，例如 [Project]、[Project PR #123]。主题尽量使用中文；专有名词、PR 编号和 RFC 名称可保留英文。
      每个输入 id 必须且只能返回一个 decision。keep 的 title 必须为 null；rename 的 title 必须是完整新标题。

      INPUT_JSON:
      #{JSON.generate(payload)}
    PROMPT
  end

  def validate_decisions(decisions, candidates)
    raise InvalidDecisionError, "decisions must be an array" unless decisions.is_a?(Array)

    expected = candidates.map { |candidate| candidate.fetch("id") }.sort
    actual = decisions.map { |decision| decision["id"] }.sort
    unless actual == expected && actual.uniq.length == actual.length
      raise InvalidDecisionError, "decision ids do not match candidates"
    end

    decisions.each do |decision|
      action = decision["action"]
      case action
      when "keep"
        unless decision["title"].nil?
          raise InvalidDecisionError, "keep decision must have null title for #{decision["id"]}"
        end
      when "rename"
        unless valid_title?(decision["title"])
          raise InvalidDecisionError, "invalid generated title for #{decision["id"]}: #{decision["title"].inspect}"
        end
      else
        raise InvalidDecisionError, "invalid decision action for #{decision["id"]}: #{action.inspect}"
      end
    end
    decisions
  end

  def run(command, stdin_text)
    env = { "CODEX_TITLE_MAINTENANCE_WORKER" => "1" }
    stdout_text = +""
    stderr_text = +""
    status = nil
    Open3.popen3(env, *command, chdir: @working_directory) do |stdin, stdout, stderr, wait_thread|
      stdout_reader = Thread.new { stdout_text << stdout.read }
      stderr_reader = Thread.new { stderr_text << stderr.read }
      stdin.write(stdin_text)
      stdin.close
      begin
        Timeout.timeout(@timeout_seconds) { status = wait_thread.value }
      rescue Timeout::Error
        Process.kill("TERM", wait_thread.pid) rescue nil
        begin
          Timeout.timeout(5) { status = wait_thread.value }
        rescue Timeout::Error
          Process.kill("KILL", wait_thread.pid) rescue nil
          status = wait_thread.value
        end
        raise "Terra title decision timed out after #{@timeout_seconds}s"
      ensure
        stdout_reader.join(5)
        stderr_reader.join(5)
      end
    end
    [stdout_text, stderr_text, status]
  end
end
