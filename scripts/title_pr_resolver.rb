#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "timeout"

class TitlePullRequestResolver
  FAILED_CHECK_RESULTS = %w[ACTION_REQUIRED CANCELLED FAILURE SKIPPED STALE STARTUP_FAILURE TIMED_OUT].freeze

  def self.default_gh
    candidates = [
      ENV["CODEX_TITLE_GH_BIN"],
      "/opt/homebrew/bin/gh",
      "/usr/local/bin/gh",
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "gh") }
    ].flatten.compact
    candidates.find { |path| File.file?(path) && File.executable?(path) } || "gh"
  end

  def initialize(gh_bin: self.class.default_gh, git_bin: "/usr/bin/git", timeout_seconds: 20)
    @gh_bin = gh_bin
    @git_bin = git_bin
    @timeout_seconds = timeout_seconds
    @repo_cache = {}
  end

  def refs_for(candidate)
    text = ([candidate["title"]] + Array(candidate.dig("context", "messages")).map { |message| message["text"] }).compact.join("\n")
    refs = text.scan(%r{https?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)}i).map do |owner, repo, number|
      normalized_repo = repo.sub(/[^A-Za-z0-9_.-].*\z/, "").sub(/\.git\z/, "")
      { "repo" => "#{owner}/#{normalized_repo}", "number" => Integer(number) }
    end

    if refs.empty? && text.match?(/(?:\bPR\b|pull request|合并请求)/i)
      numbers = text.scan(/(?:\bPR\b|pull request|合并请求)[^\d#]{0,12}#?(\d+)/i).flatten.map(&:to_i)
      repo = parse_github_repo(candidate.dig("context", "repository_url").to_s)
      repo ||= repo_for_cwd(candidate.dig("context", "cwd"))
      refs.concat(numbers.map { |number| { "repo" => repo, "number" => number } }) if repo
    end

    refs.uniq { |ref| [ref["repo"].downcase, ref["number"]] }.first(3)
  end

  def fetch(ref)
    repo = ref.fetch("repo")
    number = Integer(ref.fetch("number"))
    stdout, stderr, status = run(
      @gh_bin,
      "pr",
      "view",
      number.to_s,
      "--repo",
      repo,
      "--json",
      "number,title,state,isDraft,mergedAt,closedAt,url,reviewDecision,statusCheckRollup,headRefName,baseRefName"
    )
    raise "gh pr view failed for #{repo}##{number}: #{stderr.strip}" unless status.success?

    metadata = JSON.parse(stdout)
    metadata["repo"] = repo
    metadata["statusEmoji"] = status_emoji(metadata)
    metadata["fingerprint"] = fingerprint(metadata)
    metadata
  rescue JSON::ParserError => error
    raise "invalid gh metadata for #{repo}##{number}: #{error.message}"
  end

  def status_emoji(metadata)
    state = metadata["state"].to_s.upcase
    return "✅" if metadata["mergedAt"] || state == "MERGED"
    return "⛔" if state == "CLOSED"
    return "🔄" if metadata["isDraft"]
    return "⚠️" if failed_checks?(metadata["statusCheckRollup"])

    "🟡"
  end

  def fingerprint(metadata)
    stable = {
      "repo" => metadata["repo"],
      "number" => metadata["number"],
      "title" => metadata["title"],
      "state" => metadata["state"],
      "isDraft" => metadata["isDraft"],
      "mergedAt" => metadata["mergedAt"],
      "closedAt" => metadata["closedAt"],
      "reviewDecision" => metadata["reviewDecision"],
      "checks" => Array(metadata["statusCheckRollup"]).map do |check|
        [check["name"] || check["context"], check["status"] || check["state"], check["conclusion"]]
      end.sort_by { |item| item.map(&:to_s).join("\0") }
    }
    Digest::SHA256.hexdigest(JSON.generate(stable))
  end

  private

  def repo_for_cwd(cwd)
    return nil if cwd.to_s.empty?
    return @repo_cache[cwd] if @repo_cache.key?(cwd)

    stdout, = run(@git_bin, "-C", cwd, "remote", "get-url", "origin")
    @repo_cache[cwd] = parse_github_repo(stdout.strip)
  rescue StandardError
    @repo_cache[cwd] = nil
  end

  def parse_github_repo(remote)
    match = remote.match(%r{(?:github\.com[/:])([^/]+)/([^/]+?)(?:\.git)?\z}i)
    match ? "#{match[1]}/#{match[2]}" : nil
  end

  def failed_checks?(checks)
    Array(checks).any? do |check|
      result = (check["conclusion"] || check["state"] || check["status"]).to_s.upcase
      FAILED_CHECK_RESULTS.include?(result)
    end
  end

  def run(*command)
    stdout = stderr = nil
    status = nil
    Timeout.timeout(@timeout_seconds) { stdout, stderr, status = Open3.capture3(*command) }
    [stdout, stderr, status]
  rescue Timeout::Error
    raise "command timed out after #{@timeout_seconds}s: #{command.first}"
  end
end
