# frozen_string_literal: true

require "digest"
require "json"

# The model proposes cited changes. This reducer owns the durable contract and
# the deterministic presentation; no model output contains an emoji or title.
class TitleTaskState
  class InvalidUpdate < StandardError; end
  VERSION = 1
  KINDS = %w[outcome implementation merge deployment acceptance investigation other].freeze
  STATUSES = %w[open satisfied waived].freeze
  PROGRESS = %w[working waiting blocked monitoring cancelled].freeze

  def self.empty
    { "version" => VERSION, "goal" => nil, "requirements" => {}, "pull_requests" => {},
      "progress" => nil, "past_goals" => [] }
  end

  def apply(previous, proposal, messages)
    @messages = messages.each_with_object({}) { |message, index| index[message.fetch("id")] = message }
    state = JSON.parse(JSON.generate(previous))
    goal = proposal.fetch("goal")
    action = goal.fetch("action")
    raise InvalidUpdate, "invalid goal action" unless %w[retain start replace].include?(action)
    if action != "retain"
      raise InvalidUpdate, "start only applies to a new task" if action == "start" && state["goal"]
      raise InvalidUpdate, "replace requires an existing goal" if action == "replace" && !state["goal"]
      evidence = citations(goal.fetch("evidence"), user_only: true)
      topic = label(goal.fetch("topic"), max: 55)
      project = label(goal.fetch("project"), max: 20, empty: true)
      if state["goal"]
        state["past_goals"] << state.select { |key, _| %w[goal requirements pull_requests progress].include?(key) }
      end
      state["goal"] = { "id" => Digest::SHA256.hexdigest(JSON.generate(evidence))[0, 16],
                          "topic" => topic, "project" => project, "evidence" => evidence }
      state["requirements"] = {
        "outcome" => { "id" => "outcome", "description" => topic, "kind" => "outcome",
                       "status" => "open", "introduced_by" => evidence, "evidence" => evidence }
      }
      state["pull_requests"] = {}
      state["progress"] = { "kind" => "working", "evidence" => evidence }
    else
      # A retain operation cannot quietly rewrite the main topic.
      if !goal.fetch("topic").empty? && goal["topic"] != state.dig("goal", "topic")
        raise InvalidUpdate, "topic change requires new user evidence"
      end
      if !goal.fetch("project").empty? && goal["project"] != state.dig("goal", "project")
        raise InvalidUpdate, "project change requires new user evidence"
      end
    end

    changes = proposal.fetch("requirements")
    prs = proposal.fetch("pull_requests")
    progress = proposal.fetch("progress")
    unless state["goal"]
      raise InvalidUpdate, "cannot change a task without a user goal" unless changes.empty? && prs.empty? && progress.nil?
      return state
    end

    seen = []
    changes.each do |change|
      id = change.fetch("id")
      raise InvalidUpdate, "invalid or duplicate requirement id" unless id.match?(/\A[a-z][a-z0-9_-]{0,63}\z/) && !seen.include?(id)
      seen << id
      kind = change.fetch("kind")
      status = change.fetch("status")
      raise InvalidUpdate, "invalid requirement kind/status" unless KINDS.include?(kind) && STATUSES.include?(status)
      raise InvalidUpdate, "outcome is a reserved requirement" if (id == "outcome") != (kind == "outcome")
      existing = state["requirements"][id]
      description = label(change.fetch("description"), max: 300)
      if existing && (existing["kind"] != kind || existing["description"] != description)
        raise InvalidUpdate, "existing requirements are immutable; resolve or waive them explicitly"
      end
      evidence = citations(change.fetch("evidence"), user_only: status == "waived")
      if status == "satisfied" && %w[outcome acceptance].include?(kind)
        unless evidence.any? { |item| item["role"] == "user" || %w[final final_answer].include?(item["phase"]) }
          raise InvalidUpdate, "outcome/acceptance needs a final result or user confirmation, not commentary"
        end
      end
      state["requirements"][id] = {
        "id" => id, "kind" => kind, "description" => description, "status" => status,
        "introduced_by" => existing ? existing["introduced_by"] : evidence, "evidence" => evidence
      }
    end

    prs.each do |pr|
      repo = pr.fetch("repo").sub(%r{\Ahttps://github\.com/}i, "").sub(/\.git\z/, "").sub(/\/\z/, "")
      number = pr.fetch("number")
      relation = pr.fetch("relation")
      unless repo.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/) && number.is_a?(Integer) && number.positive? && %w[current historical].include?(relation)
        raise InvalidUpdate, "invalid PR association: #{pr.slice("repo", "number", "relation").inspect}"
      end
      key = "#{repo.downcase}##{number}"
      existing = state["pull_requests"][key]
      evidence = citations(pr.fetch("evidence"), user_only: existing && existing["relation"] == "current" && relation == "historical")
      unless evidence.any? { |item| item["quote"].include?("/pull/#{number}") || item["quote"].match?(/(?:PR\s*#?|#)#{number}(?!\d)/i) }
        raise InvalidUpdate, "PR number must appear in its cited evidence"
      end
      urls = evidence.flat_map { |item| item["quote"].scan(%r{https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)}i) }
      if urls.any? && !urls.any? { |url_repo, url_number| url_repo.casecmp(repo).zero? && url_number.to_i == number }
        raise InvalidUpdate, "PR repository must match its cited URL"
      end
      state["pull_requests"][key] = { "repo" => repo, "number" => number, "relation" => relation, "evidence" => evidence }
    end

    if progress
      kind = progress.fetch("kind")
      raise InvalidUpdate, "invalid progress" unless PROGRESS.include?(kind)
      state["progress"] = { "kind" => kind, "basis" => progress.fetch("basis", "task"), "evidence" => citations(progress.fetch("evidence"), user_only: kind == "cancelled") }
    end
    state
  rescue KeyError, NoMethodError, TypeError => error
    raise InvalidUpdate, "invalid task update: #{error.message}"
  end

  def present(state, pr_facts:, caught_up:, active_turn: false)
    return { "title" => nil, "status" => "reconstructing", "reason" => "transcript not fully consumed" } unless caught_up
    return { "title" => nil, "status" => "unknown", "reason" => "no evidenced user goal" } unless state["goal"]

    prs = state["pull_requests"].select { |_, pr| pr["relation"] == "current" }
    facts = prs.keys.map { |key| pr_facts[key] }
    unknown = facts.any? { |fact| !fact || fact["error"] || !%w[OPEN MERGED CLOSED].include?(fact["state"]) }
    all_merged = !facts.empty? && !unknown && facts.all? { |fact| fact["state"] == "MERGED" }
    pending = state["requirements"].values.reject do |requirement|
      requirement["status"] == "waived" ||
        (requirement["kind"] == "merge" ? all_merged : requirement["status"] == "satisfied")
    end
    progress = state.dig("progress", "kind")

    emoji, reason = if active_turn
                      ["🔄", "a user turn is still being processed"]
                    elsif progress == "cancelled"
                      ["⛔", "user explicitly cancelled this goal"]
                    elsif unknown
                      ["⏸️", "current PR facts unavailable"]
                    elsif (progress == "blocked" && state.dig("progress", "basis") != "pull_request") || facts.any? { |fact| fact["statusEmoji"] == "⚠️" || fact["state"] == "CLOSED" }
                      ["⚠️", "reported blocker or failed PR gate"]
                    elsif facts.any? { |fact| fact["state"] == "OPEN" && fact["isDraft"] }
                      ["🔄", "current PR is draft"]
                    elsif facts.any? { |fact| fact["state"] == "OPEN" }
                      ["🟡", "current PR is not merged"]
                    elsif progress == "monitoring"
                      ["⏱️", "monitoring remains in scope"]
                    elsif pending.empty? && state.dig("requirements", "outcome", "status") == "satisfied"
                      ["✅", "all task requirements have completion evidence"]
                    elsif progress == "working"
                      ["🔄", "task requirements remain open"]
                    else
                      ["⏸️", "waiting for outstanding task requirements"]
                    end
    tag = state["goal"]["project"].to_s
    if !prs.empty?
      last_pr = prs.values.last
      tag = [tag, "PR ##{last_pr['number']}"].reject(&:empty?).join(" ")
    end
    title = [emoji, ("[#{tag}]" unless tag.empty?), state["goal"]["topic"]].compact.join(" ")
    { "title" => title, "status" => emoji, "reason" => reason,
      "pending_requirements" => pending.map { |requirement| requirement["id"] },
      "goal_evidence" => state["goal"]["evidence"], "current_prs" => prs.keys }
  end

  private

  def citations(values, user_only: false)
    raise InvalidUpdate, "each change requires evidence" unless values.is_a?(Array) && !values.empty?
    values.map do |citation|
      message = @messages[citation.fetch("message_id")]
      quote = citation.fetch("quote")
      unless message && quote.is_a?(String) && !quote.strip.empty? && quote.length <= 1_000 && message["text"].include?(quote)
        raise InvalidUpdate, "evidence must quote a supplied message exactly: #{citation['message_id']} quote=#{quote.to_s[0, 180].inspect}; preserve Markdown punctuation or use a shorter contiguous excerpt"
      end
      raise InvalidUpdate, "goal replacement/waiver needs user evidence" if user_only && message["role"] != "user"
      citation.merge("role" => message["role"], "phase" => message["phase"])
    end
  end

  def label(value, max:, empty: false)
    unless value.is_a?(String) && value.length <= max && (empty || !value.strip.empty?) && !value.match?(/[\r\n\[\]✅⚠🔄🟡⏸⛔⏱]/)
      raise InvalidUpdate, "invalid task label"
    end
    value.strip
  end
end
