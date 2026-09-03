#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "securerandom"
require "shellwords"
require "timeout"
require_relative "codex_app_server_client"
require_relative "title_event_store"
require_relative "title_event_worker"
require_relative "title_model_decider"
require_relative "title_pr_resolver"

class TitleEventInstaller
  DEFAULT_LABEL = "local.codex-session-title-maintenance"
  HOOK_TIMEOUT_SECONDS = 5
  CANARY_TIMEOUT_SECONDS = 120
  HOOK_EVENTS = %w[SessionStart UserPromptSubmit Stop].freeze

  attr_reader :home, :codex_home, :skill_root, :hooks_path, :plist_path, :label

  def initialize(
    home: Dir.home,
    codex_home: ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex")),
    skill_root: File.expand_path("..", __dir__),
    label: ENV.fetch("CODEX_TITLE_LAUNCH_AGENT_LABEL", DEFAULT_LABEL),
    app_client_factory: -> { CodexAppServerClient.new },
    now: -> { Time.now }
  )
    @home = File.expand_path(home)
    @codex_home = File.expand_path(codex_home)
    @skill_root = File.expand_path(skill_root)
    @label = label
    @hooks_path = File.join(@codex_home, "hooks.json")
    @plist_path = File.join(@home, "Library", "LaunchAgents", "#{@label}.plist")
    @runtime_root = File.join(@codex_home, "title-maintenance")
    @hook_script = File.join(@skill_root, "scripts", "title_event_hook.rb")
    @worker_script = File.join(@skill_root, "scripts", "title_event_worker.rb")
    @app_client_factory = app_client_factory
    @now = now
    @app_server_bin = resolve_executable(
      ENV["CODEX_TITLE_APP_SERVER_BIN"],
      CodexAppServerClient.default_codex
    )
    @decision_codex = resolve_executable(
      ENV["CODEX_TITLE_CODEX_BIN"],
      TitleModelDecider.default_codex
    )
    @gh_bin = resolve_executable(
      ENV["CODEX_TITLE_GH_BIN"],
      TitlePullRequestResolver.default_gh
    )
  end

  def install(run_canary: false)
    validate_installation_inputs!
    FileUtils.mkdir_p(@runtime_root, mode: 0o700)
    hook_changed = write_hook_config
    trust = trust_hook
    plist_changed = write_launch_agent
    ensure_launch_agent(plist_changed: plist_changed)
    canary = run_canary ? run_stop_canary : nil
    health = doctor
    raise "installation did not pass health checks: #{JSON.generate(health)}" unless health["ok"]

    {
      "status" => "installed",
      "hook_config_changed" => hook_changed,
      "hook_trust" => trust,
      "launch_agent_changed" => plist_changed,
      "canary" => canary,
      "health" => health
    }
  end

  def doctor
    hook_report = hook_health
    launch_report = launch_agent_health
    legacy = legacy_automation_health
    store = TitleEventMaintenance::Store.new(root: @runtime_root)
    state = store.read_state
    binaries = {
      "ruby" => executable?("/usr/bin/ruby"),
      "app_server" => executable?(@app_server_bin),
      "decision_codex" => executable?(@decision_codex),
      "gh" => executable?(@gh_bin)
    }
    errors_path = File.join(@runtime_root, "worker-errors.log")
    hook_errors_path = File.join(@runtime_root, "hook-errors.log")
    ok = hook_report["ok"] && launch_report["ok"] && binaries.values.all? && legacy["paused_or_absent"]

    {
      "status" => ok ? "healthy" : "unhealthy",
      "ok" => ok,
      "hook" => hook_report,
      "launch_agent" => launch_report,
      "schedule" => {
        "event_processing" => "always_on",
        "pr_poll_seconds" => TitleEventWorker::PR_POLL_MS / 1000,
        "startup_warmup_cooldown_seconds" => TitleEventWorker::STARTUP_WARMUP_COOLDOWN_MS / 1000,
        "reconciliation" => "once_per_beijing_calendar_day"
      },
      "binaries" => binaries,
      "queue_size" => store.queue_size,
      "last_startup_warmup_ms" => state["last_startup_warmup_ms"],
      "last_reconcile_date" => state["last_reconcile_date"],
      "worker_retry_attempts" => state["worker_retry_attempts"],
      "worker_error_log_bytes" => File.file?(errors_path) ? File.size(errors_path) : 0,
      "hook_error_log_bytes" => File.file?(hook_errors_path) ? File.size(hook_errors_path) : 0,
      "legacy_heartbeat" => legacy
    }
  rescue StandardError => error
    {
      "status" => "unhealthy",
      "ok" => false,
      "error" => "#{error.class}: #{error.message}"
    }
  end

  def run_stop_canary
    health = hook_health
    raise "Stop hook is not trusted" unless health["ok"]

    marker = File.join(@runtime_root, "canary-#{Process.pid}-#{SecureRandom.hex(4)}.json")
    canary_root = Dir.mktmpdir("title-canary-", @runtime_root)
    env = {
      "CODEX_HOME" => @codex_home,
      "CODEX_TITLE_CANARY_PATH" => marker,
      "CODEX_TITLE_EVENT_ROOT" => canary_root,
      "CODEX_TITLE_EVENT_DISABLE_WAKE" => "1",
      "CODEX_TITLE_MAINTENANCE_WORKER" => nil
    }
    command = [
      @decision_codex,
      "exec",
      "--ephemeral",
      "--ignore-rules",
      "--skip-git-repo-check",
      "--sandbox",
      "read-only",
      "--model",
      ENV.fetch("CODEX_TITLE_CANARY_MODEL", "gpt-5.6-luna"),
      "-c",
      "model_reasoning_effort=\"low\"",
      "--color",
      "never",
      "Reply exactly OK. Do not call tools."
    ]
    stdout, stderr, status = capture_with_timeout(env, command, CANARY_TIMEOUT_SECONDS)
    unless status.success?
      detail = [stderr, stdout].map(&:strip).reject(&:empty?).join("\n")[0, 1_000]
      raise "Codex Stop canary turn failed (exit #{status.exitstatus}): #{detail}"
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.05 until File.file?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "Codex completed, but the trusted Stop hook did not write its canary marker" unless File.file?(marker)

    payload = JSON.parse(File.read(marker))
    raise "unexpected canary event: #{payload.inspect}" unless payload["hook_event_name"].to_s.casecmp("stop").zero?
    thread_id = payload["thread_id"]
    raise "Stop canary did not capture a valid thread id" unless TitleEventMaintenance.valid_thread_id?(thread_id)

    queued = TitleEventMaintenance::Store.new(root: canary_root).snapshot(
      now_ms: TitleEventMaintenance.now_ms,
      idle_ms: 0
    )
    raise "Stop canary did not reach the durable queue" unless queued.key?(thread_id)

    { "status" => "passed", "observed_at" => payload["observed_at"], "thread_id" => thread_id }
  ensure
    File.delete(marker) if defined?(marker) && marker && File.exist?(marker)
    FileUtils.remove_entry(canary_root) if defined?(canary_root) && canary_root && Dir.exist?(canary_root)
  end

  def hook_command
    "/usr/bin/ruby --disable=gems #{Shellwords.escape(@hook_script)}"
  end

  def self.merge_hook_document(document, command)
    result = JSON.parse(JSON.generate(document || {}))
    result["hooks"] = {} unless result["hooks"].is_a?(Hash)
    HOOK_EVENTS.each do |event_name|
      groups = Array(result["hooks"][event_name])
      cleaned = groups.each_with_object([]) do |group, output|
        next unless group.is_a?(Hash)

        copy = JSON.parse(JSON.generate(group))
        handlers = Array(copy["hooks"]).reject do |handler|
          title_hook_command?(handler["command"])
        end
        next if handlers.empty?

        copy["hooks"] = handlers
        output << copy
      end
      cleaned << {
        "hooks" => [
          {
            "command" => command,
            "timeout" => HOOK_TIMEOUT_SECONDS,
            "type" => "command"
          }
        ]
      }
      result["hooks"][event_name] = cleaned
    end
    result
  end

  def self.title_hook_command?(command)
    command.to_s.include?("codex-session-title-maintenance/scripts/title_event_hook.rb")
  end

  def self.trust_key_path(hook_key)
    "hooks.state.#{JSON.generate(hook_key)}.trusted_hash"
  end

  private

  def validate_installation_inputs!
    missing = [@hook_script, @worker_script].reject { |path| File.file?(path) }
    raise "missing skill scripts: #{missing.join(', ')}" unless missing.empty?
    raise "Desktop/current Codex app-server binary is unavailable" unless executable?(@app_server_bin)
    raise "Codex CLI for Terra decisions is unavailable" unless executable?(@decision_codex)
    raise "GitHub CLI is unavailable" unless executable?(@gh_bin)
    raise "system Ruby is unavailable" unless executable?("/usr/bin/ruby")
  end

  def write_hook_config
    original_text = File.file?(@hooks_path) ? File.read(@hooks_path) : "{}\n"
    original = JSON.parse(original_text)
    updated = self.class.merge_hook_document(original, hook_command)
    return false if updated == original

    backup = "#{@hooks_path}.title-maintenance.bak"
    TitleEventMaintenance.atomic_write(backup, original_text) if File.file?(@hooks_path) && !File.exist?(backup)
    TitleEventMaintenance.atomic_write(@hooks_path, JSON.pretty_generate(updated) + "\n")
    true
  rescue JSON::ParserError => error
    raise "cannot install into invalid #{@hooks_path}: #{error.message}"
  end

  def trust_hook
    entries = nil
    @app_client_factory.call.connect do |client|
      entries = matching_hook_entries(client.list_hooks(cwds: [@home]))
      validate_hook_entries!(entries)
      writes = entries.reject { |entry| entry["trustStatus"] == "trusted" }.map do |entry|
        {
          "keyPath" => self.class.trust_key_path(entry.fetch("key")),
          "value" => entry.fetch("currentHash"),
          "mergeStrategy" => "upsert"
        }
      end
      unless writes.empty?
        client.batch_write_config(
          writes
        )
      end
    end

    verified = hook_health
    raise "Codex did not persist trust for all title hooks" unless verified["ok"]

    {
      "events" => verified["events"],
      "status" => "trusted"
    }
  end

  def hook_health
    entries = nil
    @app_client_factory.call.connect do |client|
      entries = matching_hook_entries(client.list_hooks(cwds: [@home]))
    end
    events = HOOK_EVENTS.each_with_object({}) do |event_name, result|
      matches = entries.select { |entry| entry["eventName"].to_s.casecmp(event_name).zero? }
      entry = matches.first
      result[event_name] = {
        "ok" => matches.length == 1 && entry["enabled"] && entry["trustStatus"] == "trusted",
        "matching_entries" => matches.length,
        "enabled" => entry && entry["enabled"],
        "trust_status" => entry && entry["trustStatus"],
        "key" => entry && entry["key"],
        "current_hash" => entry && entry["currentHash"]
      }
    end
    {
      "ok" => events.values.all? { |event| event["ok"] },
      "events" => events
    }
  end

  def matching_hook_entries(entries)
    Array(entries).select do |hook|
      HOOK_EVENTS.any? { |event_name| hook["eventName"].to_s.casecmp(event_name).zero? } && hook["command"] == hook_command
    end
  end

  def validate_hook_entries!(entries)
    HOOK_EVENTS.each do |event_name|
      count = entries.count { |entry| entry["eventName"].to_s.casecmp(event_name).zero? }
      raise "expected exactly one installed #{event_name} hook, found #{count}" unless count == 1
    end
  end

  def write_launch_agent
    content = launch_agent_plist
    original = File.file?(@plist_path) ? File.read(@plist_path) : nil
    return false if original == content

    FileUtils.mkdir_p(File.dirname(@plist_path))
    backup = "#{@plist_path}.title-maintenance.bak"
    TitleEventMaintenance.atomic_write(backup, original, mode: 0o644) if original && !File.exist?(backup)
    TitleEventMaintenance.atomic_write(@plist_path, content, mode: 0o644)
    _stdout, stderr, status = Open3.capture3("/usr/bin/plutil", "-lint", @plist_path)
    raise "generated LaunchAgent is invalid: #{stderr.strip}" unless status.success?

    true
  end

  def launch_agent_plist
    env = {
      "CODEX_TITLE_APP_SERVER_BIN" => @app_server_bin,
      "CODEX_TITLE_CODEX_BIN" => @decision_codex,
      "CODEX_TITLE_CODEX_DIR" => @codex_home,
      "CODEX_TITLE_EVENT_ROOT" => @runtime_root,
      "CODEX_TITLE_GH_BIN" => @gh_bin,
      "CODEX_TITLE_LAUNCH_AGENT_LABEL" => @label,
      "CODEX_TITLE_MODEL_CWD" => @home,
      "HOME" => @home,
      "LANG" => "en_US.UTF-8",
      "PATH" => executable_path
    }
    if (owner = ENV["CODEX_TITLE_OWNER_ID"]) && !owner.empty?
      env["CODEX_TITLE_OWNER_ID"] = owner
    end
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>#{xml(@label)}</string>
        <key>ProgramArguments</key>
        <array>
          <string>/usr/bin/ruby</string>
          <string>--disable=gems</string>
          <string>#{xml(@worker_script)}</string>
          <string>--daemon</string>
        </array>
        <key>EnvironmentVariables</key>
        <dict>
      #{env.sort.map { |key, value| "    <key>#{xml(key)}</key>\n    <string>#{xml(value)}</string>" }.join("\n")}
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
          <key>SuccessfulExit</key>
          <false/>
        </dict>
        <key>ThrottleInterval</key>
        <integer>30</integer>
        <key>ProcessType</key>
        <string>Background</string>
        <key>LowPriorityIO</key>
        <true/>
        <key>StandardOutPath</key>
        <string>#{xml(File.join(@runtime_root, 'worker.log'))}</string>
        <key>StandardErrorPath</key>
        <string>#{xml(File.join(@runtime_root, 'worker-errors.log'))}</string>
      </dict>
      </plist>
    PLIST
  end

  def ensure_launch_agent(plist_changed:)
    domain = "gui/#{Process.uid}"
    service = "#{domain}/#{@label}"
    _stdout, _stderr, loaded = Open3.capture3("/bin/launchctl", "print", service)
    if loaded.success? && !plist_changed
      _stdout, stderr, status = Open3.capture3("/bin/launchctl", "kickstart", "-k", service)
      raise "failed to restart LaunchAgent: #{stderr.strip}" unless status.success?
      return
    end

    if loaded.success?
      _stdout, stderr, status = Open3.capture3("/bin/launchctl", "bootout", service)
      raise "failed to stop existing LaunchAgent: #{stderr.strip}" unless status.success?
      20.times do
        _check_out, _check_err, check = Open3.capture3("/bin/launchctl", "print", service)
        break unless check.success?

        sleep 0.05
      end
    end

    bootstrap_error = nil
    4.times do |attempt|
      _stdout, stderr, status = Open3.capture3("/bin/launchctl", "bootstrap", domain, @plist_path)
      if status.success?
        bootstrap_error = nil
        break
      end

      bootstrap_error = stderr.strip
      sleep(0.15 * (attempt + 1))
    end
    raise "failed to load LaunchAgent after retries: #{bootstrap_error}" if bootstrap_error

    _stdout, stderr, status = Open3.capture3("/bin/launchctl", "kickstart", "-k", service)
    raise "failed to start LaunchAgent: #{stderr.strip}" unless status.success?
  end

  def launch_agent_health
    service = "gui/#{Process.uid}/#{@label}"
    stdout, stderr, status = Open3.capture3("/bin/launchctl", "print", service)
    plist_ok = false
    if File.file?(@plist_path)
      _lint_out, _lint_err, lint = Open3.capture3("/usr/bin/plutil", "-lint", @plist_path)
      plist_ok = lint.success?
    end
    {
      "ok" => status.success? && plist_ok,
      "loaded" => status.success?,
      "plist_valid" => plist_ok,
      "pid" => stdout[/\bpid = (\d+)/, 1]&.to_i,
      "last_exit_status" => stdout[/\blast exit code = (-?\d+)/, 1]&.to_i,
      "error" => status.success? ? nil : stderr.strip[0, 500]
    }
  end

  def legacy_automation_health
    path = File.join(@codex_home, "automations", "codex-session", "automation.toml")
    status = File.file?(path) ? File.read(path)[/^status\s*=\s*"([^"]+)"/, 1] : nil
    {
      "present" => File.file?(path),
      "status" => status,
      "paused_or_absent" => !File.file?(path) || status == "PAUSED"
    }
  end

  def executable_path
    dirs = [
      File.dirname(@decision_codex),
      File.dirname(@gh_bin),
      File.dirname(@app_server_bin),
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin"
    ].select { |path| path.start_with?("/") }.uniq
    dirs.join(File::PATH_SEPARATOR)
  end

  def resolve_executable(*candidates)
    candidates.flatten.compact.each do |candidate|
      return candidate if executable?(candidate)
      next if candidate.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, candidate)
        return path if executable?(path)
      end
    end
    candidates.flatten.compact.last
  end

  def executable?(path)
    path && File.file?(path) && File.executable?(path)
  end

  def capture_with_timeout(env, command, seconds)
    stdout = +""
    stderr = +""
    status = nil
    Open3.popen3(env, *command, chdir: @home) do |stdin, out, err, wait_thread|
      stdin.close
      out_reader = Thread.new { stdout << out.read }
      err_reader = Thread.new { stderr << err.read }
      begin
        Timeout.timeout(seconds) { status = wait_thread.value }
      rescue Timeout::Error
        Process.kill("TERM", wait_thread.pid) rescue nil
        raise "Codex Stop canary timed out after #{seconds}s"
      ensure
        out_reader.join(5)
        err_reader.join(5)
      end
    end
    [stdout, stderr, status]
  end

  def xml(value)
    CGI.escapeHTML(value.to_s)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift || "doctor"
    options = { canary: false }
    OptionParser.new do |opts|
      opts.banner = "Usage: title_event_install.rb [install|doctor|canary] [options]"
      opts.on("--canary", "Run a real Codex Stop-hook canary after installation") { options[:canary] = true }
    end.parse!(ARGV)

    installer = TitleEventInstaller.new
    result = case command
             when "install"
               installer.install(run_canary: options[:canary])
             when "doctor"
               installer.doctor
             when "canary"
               installer.run_stop_canary
             else
               raise "unknown command: #{command}"
             end
    puts JSON.pretty_generate(result)
    exit(result.is_a?(Hash) && result["ok"] == false ? 1 : 0)
  rescue StandardError => error
    warn JSON.pretty_generate("status" => "error", "error" => "#{error.class}: #{error.message}")
    exit 1
  end
end
