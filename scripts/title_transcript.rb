# frozen_string_literal: true

require "digest"
require "json"

# A cursor is a position in the source, not a title timestamp. Every meaningful
# message is visited, even when reconstruction needs several worker passes.
class TitleTranscript
  class SourceChanged < StandardError; end
  MAX_MESSAGES = 80
  MAX_CHARS = 60_000
  SEGMENT_CHARS = 8_000
  MAX_SCAN_BYTES = 64 * 1024 * 1024
  INJECTED_TAGS = %w[recommended_plugins environment_context in-app-browser-context skill permissions\ instructions skills_instructions].freeze

  def read(path, cursor: nil, max_messages: MAX_MESSAGES, max_chars: MAX_CHARS)
    raise SourceChanged, "transcript missing" unless path && File.file?(path)

    File.open(path, "rb") do |file|
      boundary = file.stat.size
      validate_cursor!(file, cursor) if cursor
      position = cursor ? cursor.fetch("offset") : 0
      segment = cursor ? cursor.fetch("segment", 0) : 0
      file.seek(position)
      messages = []
      chars = 0
      scanned = 0
      metadata = (cursor && cursor["metadata"] || {}).dup
      partial = false
      last_user_id = cursor && cursor["last_user_id"]
      last_message = cursor && cursor["last_message"]

      while file.pos < boundary && messages.length < max_messages && chars < max_chars && scanned < MAX_SCAN_BYTES
        start = file.pos
        line = file.gets
        break unless line
        if !line.end_with?("\n") || file.pos > boundary
          partial = true
          position = start
          break
        end
        scanned += line.bytesize
        item = JSON.parse(line)
        payload = item["payload"] || {}
        if item["type"] == "session_meta"
          metadata["thread_id"] ||= payload["id"]
          metadata["cwd"] ||= payload["cwd"]
          metadata["repository_url"] ||= payload.dig("git", "repository_url") if payload["git"].is_a?(Hash)
          metadata["originator"] ||= payload["originator"]
        end
        text = visible_text(item)
        if text
          if payload["role"] == "user" && (text.include?("Automation ID: codex-session") || text.include?("每小时整理近期 Codex Session 标题"))
            metadata["automation_run"] = true
          end
          parts = (text.length.to_f / SEGMENT_CHARS).ceil
          while segment < parts && messages.length < max_messages && chars < max_chars
            body = text[segment * SEGMENT_CHARS, SEGMENT_CHARS]
            id = "m#{start}:#{segment}"
            message = {
              "id" => id, "role" => payload["role"], "phase" => payload["phase"],
              "timestamp" => item["timestamp"], "text" => body,
              "part" => segment + 1, "parts" => parts
            }
            messages << message
            last_message = message.slice("role", "phase", "timestamp")
            last_user_id = id if payload["role"] == "user"
            chars += body.length
            segment += 1
          end
          if segment < parts
            position = start
            break
          end
        end
        segment = 0
        position = file.pos
      end

      next_cursor = checkpoint(file, position, segment).merge("metadata" => metadata, "last_user_id" => last_user_id, "last_message" => last_message)
      {
        "messages" => messages, "cursor" => next_cursor, "metadata" => metadata,
        "caught_up" => position == boundary && segment.zero? && !partial,
        "source_size" => boundary, "partial_line" => partial
      }
    end
  rescue JSON::ParserError => error
    # A complete corrupt record is not permission to silently skip evidence.
    raise SourceChanged, "invalid transcript record: #{error.class}"
  end

  # Tool/log appends do not invalidate a topic; a new visible message does.
  def unchanged?(path, cursor, user_only: false)
    current = cursor
    loop do
      batch = read(path, cursor: current)
      return false if batch["messages"].any? { |message| !user_only || message["role"] == "user" }
      return true if batch["caught_up"]
      return false if batch["partial_line"]
      current = batch["cursor"]
    end
  rescue SourceChanged
    false
  end

  private

  def visible_text(item)
    payload = item["payload"] || {}
    return nil unless item["type"] == "response_item" && payload["type"] == "message"
    return nil unless %w[user assistant].include?(payload["role"])
    return nil if payload["role"] == "assistant" && payload["phase"] == "analysis"

    content = payload["content"]
    text = if content.is_a?(String)
             content
           else
             Array(content).select { |part| part.is_a?(Hash) }.map { |part| part["text"] || part["input_text"] || part["output_text"] }.compact.join("\n")
           end
    if payload["role"] == "user"
      return nil if text.lstrip.start_with?("# AGENTS.md instructions", "<heartbeat>")
      INJECTED_TAGS.each do |tag|
        text = text.gsub(/<#{Regexp.escape(tag)}\b[^>]*>.*?<\/#{Regexp.escape(tag)}>/m, "")
      end
    end
    text = text.strip
    text.empty? ? nil : text
  end

  def checkpoint(file, offset, segment)
    prefix_length = [file.stat.size, 256].min
    file.seek(0)
    prefix_hash = Digest::SHA256.hexdigest(file.read(prefix_length).to_s)
    anchor_start = [offset - 256, 0].max
    file.seek(anchor_start)
    anchor_hash = Digest::SHA256.hexdigest(file.read(offset - anchor_start).to_s)
    { "offset" => offset, "segment" => segment, "prefix_length" => prefix_length,
      "prefix_hash" => prefix_hash, "anchor_hash" => anchor_hash }
  end

  def validate_cursor!(file, cursor)
    offset = cursor.fetch("offset")
    raise SourceChanged, "transcript truncated" if offset > file.stat.size
    file.seek(0)
    prefix = Digest::SHA256.hexdigest(file.read(cursor.fetch("prefix_length")).to_s)
    file.seek([offset - 256, 0].max)
    anchor = Digest::SHA256.hexdigest(file.read([offset, 256].min).to_s)
    unless prefix == cursor.fetch("prefix_hash") && anchor == cursor.fetch("anchor_hash")
      raise SourceChanged, "transcript replaced; reconstruction required"
    end
  end
end
