#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require "tmpdir"

class CodexAppServerClient
  DESKTOP_CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
  WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def self.default_codex
    candidates = [
      ENV["CODEX_TITLE_APP_SERVER_BIN"],
      DESKTOP_CODEX,
      File.expand_path("~/.vite-plus/bin/codex"),
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "codex") }
    ].flatten.compact
    candidates.find { |path| File.file?(path) && File.executable?(path) } || DESKTOP_CODEX
  end

  def initialize(command: nil, socket_path: nil, timeout_seconds: 15)
    @command = command
    @socket_path = socket_path
    @timeout_seconds = timeout_seconds
    @manage_server = command.nil? && socket_path.nil?
    @request_id = 0
    @notifications = []
    @stderr_text = +""
    @read_buffer = +"".b
  end

  def connect
    raise "app-server client is already connected" if @connected

    if @command
      connect_command_transport
    else
      start_managed_server if @manage_server
      connect_websocket_transport
    end
    @connected = true

    response = request(
      "initialize",
      {
        "clientInfo" => { "name" => "codex-session-title-maintenance", "version" => "1.0" },
        "capabilities" => { "experimentalApi" => true }
      }
    )
    raise "app-server initialize failed: #{response.inspect}" unless response["result"].is_a?(Hash)

    notify("initialized", {})
    return self unless block_given?

    begin
      yield self
    ensure
      close
    end
  rescue StandardError
    close
    raise
  end

  def read_thread(thread_id, include_turns: false)
    response = request("thread/read", { "threadId" => thread_id, "includeTurns" => include_turns })
    result = response["result"]
    raise "thread/read returned no thread for #{thread_id}" unless result.is_a?(Hash) && result["thread"].is_a?(Hash)

    result["thread"]
  end

  def set_thread_name(thread_id, name)
    response = request("thread/name/set", { "threadId" => thread_id, "name" => name })
    raise "thread/name/set failed for #{thread_id}: #{response.inspect}" unless response.key?("result")

    response["result"]
  end

  def list_hooks(cwds: [Dir.home])
    response = request("hooks/list", { "cwds" => cwds })
    Array(response.dig("result", "data")).flat_map { |entry| Array(entry["hooks"]) }
  end

  def read_config(cwd: Dir.home, include_layers: false)
    response = request("config/read", { "cwd" => cwd, "includeLayers" => include_layers })
    result = response["result"]
    raise "config/read returned no config" unless result.is_a?(Hash) && result["config"].is_a?(Hash)

    result
  end

  def batch_write_config(edits, reload_user_config: true)
    response = request(
      "config/batchWrite",
      {
        "edits" => edits,
        "reloadUserConfig" => reload_user_config
      }
    )
    raise "config/batchWrite failed: #{response.inspect}" unless response.key?("result")

    response["result"]
  end

  def request(method, params)
    ensure_connected!
    @request_id += 1
    id = @request_id
    write_message("id" => id, "method" => method, "params" => params)
    wait_for_response(id)
  end

  def notify(method, params = {})
    ensure_connected!
    write_message("method" => method, "params" => params)
  end

  def close
    if @transport == :websocket
      write_websocket_frame("".b, opcode: 0x8) rescue nil
      @socket.close if @socket && !@socket.closed?
    elsif @transport == :command
      @stdin.close if @stdin && !@stdin.closed?
      stop_process(@wait_thread)
      @stdout.close if @stdout && !@stdout.closed?
      @stderr.close if @stderr && !@stderr.closed?
      @stderr_reader.join(1) if @stderr_reader
    end
    stop_managed_server
  ensure
    @connected = false
    @transport = nil
    @socket = @stdin = @stdout = @stderr = @wait_thread = @stderr_reader = nil
  end

  private

  def connect_command_transport
    @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*@command)
    @stderr_reader = Thread.new do
      begin
        loop { @stderr_text << @stderr.readpartial(4096) }
      rescue EOFError, IOError
        nil
      end
    end
    @transport = :command
  end

  def start_managed_server
    root = ENV.fetch("CODEX_TITLE_EVENT_ROOT", File.expand_path("~/.codex/title-maintenance"))
    FileUtils.mkdir_p(root, mode: 0o700)
    @server_dir = Dir.mktmpdir("app-server-", root)
    @socket_path = File.join(@server_dir, "server.sock")
    codex_bin = ENV.fetch("CODEX_TITLE_APP_SERVER_BIN", self.class.default_codex)
    command = [codex_bin, "-c", "features.code_mode_host=true", "app-server", "--listen", "unix://#{@socket_path}"]
    @server_stdin, @server_stdout, @server_stderr, @server_wait_thread = Open3.popen3(
      { "CODEX_TITLE_MAINTENANCE_WORKER" => "1" },
      *command
    )
    @server_stdin.close
    @server_stdout_reader = Thread.new { @server_stdout.read }
    @server_stderr_reader = Thread.new { @stderr_text << @server_stderr.read }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
    until File.socket?(@socket_path)
      raise "managed app-server exited before binding: #{@stderr_text.strip}" unless @server_wait_thread.alive?
      raise "managed app-server did not bind #{@socket_path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def connect_websocket_transport
    @socket = UNIXSocket.new(@socket_path)
    key = Base64.strict_encode64(SecureRandom.random_bytes(16))
    request = [
      "GET / HTTP/1.1",
      "Host: localhost",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: #{key}",
      "Sec-WebSocket-Version: 13",
      "\r\n"
    ].join("\r\n")
    @socket.write(request)
    headers = read_http_headers
    status = headers.lines.first.to_s
    expected_accept = Base64.strict_encode64(Digest::SHA1.digest(key + WEBSOCKET_GUID))
    raise "app-server websocket upgrade failed: #{status.strip}" unless status.include?(" 101 ")
    raise "app-server websocket accept mismatch" unless headers.downcase.include?("sec-websocket-accept: #{expected_accept.downcase}")

    @transport = :websocket
  end

  def read_http_headers
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
    until (boundary = @read_buffer.index("\r\n\r\n"))
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "app-server websocket handshake timed out" if remaining <= 0

      ready = IO.select([@socket], nil, nil, remaining)
      raise "app-server websocket handshake timed out" unless ready

      @read_buffer << @socket.readpartial(4096)
    end
    headers = @read_buffer.byteslice(0, boundary + 4)
    @read_buffer = @read_buffer.byteslice(boundary + 4..-1).to_s.b
    headers
  end

  def ensure_connected!
    raise "app-server client is not connected" unless @connected
    if @transport == :command
      raise "app-server exited early: #{@stderr_text.strip}" unless @wait_thread.alive?
    elsif @socket.closed?
      raise "app-server websocket is closed"
    end
  end

  def write_message(message)
    payload = JSON.generate(message)
    if @transport == :command
      @stdin.write(payload)
      @stdin.write("\n")
      @stdin.flush
    else
      write_websocket_frame(payload.b, opcode: 0x1)
    end
  rescue Errno::EPIPE, IOError => error
    raise "failed to write app-server request: #{error.message}; #{@stderr_text.strip}"
  end

  def wait_for_response(id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "app-server request #{id} timed out; #{@stderr_text.strip}" if remaining <= 0

      raw = @transport == :command ? read_command_message(remaining) : read_websocket_message(remaining)
      message = JSON.parse(raw)
      if message["id"] == id
        raise "app-server error for request #{id}: #{message["error"].inspect}" if message["error"]

        return message
      end
      @notifications << message if message["method"]
    rescue JSON::ParserError
      next
    end
  end

  def read_command_message(timeout_seconds)
    ready = IO.select([@stdout], nil, nil, timeout_seconds)
    raise "app-server response timed out; #{@stderr_text.strip}" unless ready

    line = @stdout.gets
    raise "app-server closed before response completed; #{@stderr_text.strip}" unless line

    line
  end

  def read_websocket_message(timeout_seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    message = +"".b
    started = false
    loop do
      frame = read_websocket_frame(deadline)
      case frame[:opcode]
      when 0x1
        message << frame[:payload]
        started = true
      when 0x0
        message << frame[:payload] if started
      when 0x8
        raise "app-server websocket closed; #{@stderr_text.strip}"
      when 0x9
        write_websocket_frame(frame[:payload], opcode: 0xA)
        next
      when 0xA
        next
      end
      return message if started && frame[:fin]
    end
  end

  def read_websocket_frame(deadline)
    header = read_exact(2, deadline)
    first, second = header.bytes
    fin = (first & 0x80) != 0
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    length = read_exact(2, deadline).unpack1("n") if length == 126
    length = read_exact(8, deadline).unpack1("Q>") if length == 127
    mask = masked ? read_exact(4, deadline).bytes : nil
    payload = read_exact(length, deadline)
    if mask
      payload = payload.bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }.pack("C*")
    end
    { fin: fin, opcode: opcode, payload: payload }
  end

  def read_exact(length, deadline)
    while @read_buffer.bytesize < length
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "app-server websocket response timed out; #{@stderr_text.strip}" if remaining <= 0

      ready = IO.select([@socket], nil, nil, remaining)
      raise "app-server websocket response timed out; #{@stderr_text.strip}" unless ready

      @read_buffer << @socket.readpartial([4096, length - @read_buffer.bytesize].max)
    end
    result = @read_buffer.byteslice(0, length)
    @read_buffer = @read_buffer.byteslice(length..-1).to_s.b
    result
  rescue EOFError
    raise "app-server websocket closed; #{@stderr_text.strip}"
  end

  def write_websocket_frame(payload, opcode:)
    payload = payload.b
    first = 0x80 | opcode
    length = payload.bytesize
    header = [first]
    if length < 126
      header << (0x80 | length)
    elsif length <= 0xFFFF
      header << (0x80 | 126)
      header.concat([length].pack("n").bytes)
    else
      header << (0x80 | 127)
      header.concat([length].pack("Q>").bytes)
    end
    mask = SecureRandom.random_bytes(4)
    mask_bytes = mask.bytes
    masked = payload.bytes.each_with_index.map { |byte, index| byte ^ mask_bytes[index % 4] }.pack("C*")
    @socket.write(header.pack("C*") + mask + masked)
  end

  def stop_managed_server
    return unless @server_wait_thread

    Process.kill("TERM", @server_wait_thread.pid) rescue nil
    stop_process(@server_wait_thread)
    @server_stdout.close if @server_stdout && !@server_stdout.closed?
    @server_stderr.close if @server_stderr && !@server_stderr.closed?
    @server_stdout_reader.join(1) if @server_stdout_reader
    @server_stderr_reader.join(1) if @server_stderr_reader
    FileUtils.remove_entry(@server_dir) if @server_dir && Dir.exist?(@server_dir)
  ensure
    @server_stdin = @server_stdout = @server_stderr = @server_wait_thread = nil
    @server_stdout_reader = @server_stderr_reader = @server_dir = nil
  end

  def stop_process(wait_thread)
    return unless wait_thread

    begin
      Timeout.timeout(2) { wait_thread.value }
    rescue Timeout::Error
      Process.kill("TERM", wait_thread.pid) rescue nil
      begin
        Timeout.timeout(2) { wait_thread.value }
      rescue Timeout::Error
        Process.kill("KILL", wait_thread.pid) rescue nil
        wait_thread.value
      end
    end
  end
end
