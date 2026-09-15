# frozen_string_literal: true
require "minitest/autorun"
require "tempfile"
require_relative "../scripts/title_maintenance"
require_relative "../scripts/title_model_decider"

class TitleTopicContextTest < Minitest::Test
  def test_new_user_goal_survives_assistant_chatter_and_ambient_context
    Tempfile.create("topic") do |file|
      messages = [
        ["user", "先做 iMessage，参考 Telegram"],
        ["user", "<in-app-browser-context>" + ("noise " * 300) + "</in-app-browser-context>\n改做微信接入"],
        ["user", "<skill>embedded instructions</skill>"]
      ] + Array.new(8) { ["assistant", "检查通过，继续处理"] }
      messages.each do |role, text|
        file.puts JSON.generate("type" => "response_item", "payload" => {
          "type" => "message", "role" => role, "content" => text
        })
      end
      file.flush
      context = TitleMaintenance.new.send(:extract_context, file.path)
      assert_equal "改做微信接入", context.fetch("recent_user_messages").last.fetch("text")
      refute context.fetch("messages").any? { |m| m["text"].include?("改做微信") }
      prompt = TitleModelDecider.new.send(:prompt_for, [{"id" => "one", "context" => context}])
      assert_includes prompt, "改做微信接入"
      refute_includes prompt, "embedded instructions"
    end
  end
end

