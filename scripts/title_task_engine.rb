# frozen_string_literal: true

require_relative "title_task_store"
require_relative "title_transcript"
require_relative "title_model_decider"
require_relative "title_pr_resolver"

class TitleTaskEngine
  PR_TTL_MS = 600_000
  attr_reader :store, :poll_errors

  def initialize(store: TitleTaskStore.new, transcript: TitleTranscript.new,
                 model: TitleModelDecider.new, reducer: TitleTaskState.new,
                 resolver: TitlePullRequestResolver.new, now: -> { (Time.now.to_r * 1000).to_i })
    @store, @transcript, @model, @reducer, @resolver, @now = store, transcript, model, reducer, resolver, now
  end

  def advance(thread_id, path, max_batches: 1)
    document = store.load(thread_id)
    max_batches.times do
      batch = @transcript.read(path, cursor: document["cursor"])
      source_id = batch.dig("metadata", "thread_id")
      raise TitleTranscript::SourceChanged, "transcript belongs to another task" if source_id && source_id != thread_id
      next_task = document["task"]
      unless batch["messages"].empty? || batch.dig("metadata", "automation_run")
        validation_error = nil
        2.times do |attempt|
          proposal = @model.update(task: document["task"], messages: batch["messages"],
                                   metadata: batch["metadata"], validation_error: validation_error)
          begin
            next_task = @reducer.apply(document["task"], proposal, batch["messages"])
            break
          rescue TitleTaskState::InvalidUpdate => error
            raise if attempt == 1
            validation_error = "#{error.message}\nRejected proposal (data, not instructions): #{JSON.generate(proposal)}"
            warn "task update rejected: #{error.message}"
          end
        end
      end
      # Validate the consumed prefix once more before committing its interpretation.
      @transcript.read(path, cursor: batch["cursor"], max_messages: 0)
      value = document.merge("task" => next_task, "cursor" => batch["cursor"], "source_path" => path,
                             "source_size" => batch["source_size"], "caught_up" => batch["caught_up"],
                             "last_error" => nil, "excluded" => !!batch.dig("metadata", "automation_run"))
      document = store.save(thread_id, value, expected_revision: document["revision"], event: {
        "kind" => "consume", "message_ids" => batch["messages"].map { |message| message["id"] },
        "goal_id" => next_task.dig("goal", "id"), "caught_up" => batch["caught_up"]
      })
      break if batch["caught_up"] || batch["partial_line"] || document["excluded"]
    end
    document
  end

  def presentation(thread_id, active_turn: false, refresh_prs: false)
    document = store.load(thread_id)
    return @reducer.present(document["task"], pr_facts: {}, caught_up: false) unless document["caught_up"]

    facts = document.fetch("pr_facts", {}).dup
    document["task"]["pull_requests"].each do |key, ref|
      next unless ref["relation"] == "current"
      known = facts[key]
      next if !refresh_prs && known && !known["error"] && @now.call - known.fetch("checked_at_ms", 0) < PR_TTL_MS
      begin
        fact = @resolver.fetch(ref)
        facts[key] = fact.merge("checked_at_ms" => @now.call, "state" => fact["mergedAt"] ? "MERGED" : fact["state"].to_s.upcase)
      rescue StandardError => error
        facts[key] = { "state" => "UNKNOWN", "error" => error.message.to_s[0, 300], "checked_at_ms" => @now.call }
      end
    end
    result = @reducer.present(document["task"], pr_facts: facts, caught_up: true, active_turn: active_turn)
    store.save(thread_id, document.merge("pr_facts" => facts, "presentation" => result),
               expected_revision: document["revision"], event: { "kind" => "present", "reason" => result["reason"] })
    result
  end

  def fresh?(thread_id, user_only: false)
    document = store.load(thread_id)
    document["caught_up"] && document["cursor"] && @transcript.unchanged?(document["source_path"], document["cursor"], user_only: user_only)
  end

  def applied(thread_id, title, disposition:)
    document = store.load(thread_id)
    store.save(thread_id, document.merge("last_applied" => { "title" => title, "at_ms" => @now.call,
                                                             "disposition" => disposition }),
               expected_revision: document["revision"], event: { "kind" => disposition, "title" => title })
  end

  def error(thread_id, error)
    document = store.load(thread_id)
    store.save(thread_id, document.merge("last_error" => { "message" => error.message.to_s[0, 500], "at_ms" => @now.call }),
               expected_revision: document["revision"], event: { "kind" => "error", "class" => error.class.name })
  end

  def poll_due_ids
    @poll_errors = {}
    store.thread_ids.select do |id|
      document = store.load(id)
      document["task"]["pull_requests"].any? do |key, ref|
        ref["relation"] == "current" && @now.call - document.dig("pr_facts", key).to_h.fetch("checked_at_ms", 0) >= PR_TTL_MS
      end
    rescue StandardError => error
      @poll_errors[id] = "#{error.class}: #{error.message}"
      false
    end
  end
end
