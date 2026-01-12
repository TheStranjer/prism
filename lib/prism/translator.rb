# frozen_string_literal: true

require "json"
require "set"
require "yaml"

module Prism
  class Translator
    def initialize(repo:, commit:, source_file:, target_languages:, engine:, api_token:, model:, author_name:, author_email:, github_token:, repo_slug:, retries: 5, delivery_method: "pull_request")
      @repo = repo
      @commit = commit
      @source_file = source_file
      @target_languages = target_languages
      @engine_name = engine
      @api_token = api_token
      @model = model
      @author_name = author_name
      @author_email = author_email
      @github_token = github_token
      @repo_slug = repo_slug
      @retries = retries
      @delivery_method = delivery_method
    end

    def run
      diff = DiffExaminer.new(repo: @repo, commit: @commit, source_file: @source_file)
      return :unchanged if diff.unchanged?

      engine = build_engine
      result = diff.changed_strings
      requests, backfilled_keys = build_translation_requests(result)
      return :no_strings if requests.empty?

      puts "Changed strings: #{JSON.pretty_generate(result.changed_strings)}"
      unless backfilled_keys.empty?
        puts "Backfilled strings: #{JSON.pretty_generate(backfilled_keys.sort)}"
      end

      translations = translate_strings(engine, requests)

      puts "Translations: #{JSON.pretty_generate(translations)}"

      updated_paths = apply_translations(translations, result.source_locale_root)
      return :no_updates if updated_paths.empty?
      puts "Updated locale files: #{JSON.pretty_generate(updated_paths)}"

      delivery = delivery_method
      branch = if delivery == "pull_request"
                 "i18n/auto-translate-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
               else
                 @repo.current_branch
               end
      if delivery == "push" && (branch.nil? || branch.empty? || branch == "HEAD")
        raise "Cannot push translation commit because current branch is detached."
      end
      @repo.set_identity(@author_name, @author_email)
      @repo.checkout_new_branch(branch) if delivery == "pull_request"
      @repo.add(updated_paths)

      staged_diff = @repo.staged_diff
      raise "Failed to get staged diff" if staged_diff.nil?

      source_commit_diff = @repo.show_commit(@commit)
      raise "Failed to get source commit diff" if source_commit_diff.nil?

      commit_content = engine.generate_commit_content(
        source_commit_diff: source_commit_diff,
        staged_diff: staged_diff,
        delivery_method: delivery
      )
      puts "Generated commit content: #{JSON.pretty_generate(commit_content)}"

      before_head = @repo.head_sha
      commit_output, commit_status = @repo.commit(commit_content["commit_message"])
      unless commit_status.success?
        raise "Failed to create commit: #{commit_output}"
      end

      commit_sha = @repo.head_sha
      if commit_sha.nil? || commit_sha == before_head
        raise "Commit did not advance HEAD. Output: #{commit_output.strip}"
      end

      expected_paths = updated_paths.map { |path| @repo.relative_path(path).sub(%r{\A\./}, "") }.uniq
      changed_files = @repo.changed_files(commit_sha)
      missing = expected_paths - changed_files
      extra = changed_files - expected_paths
      unless missing.empty?
        raise "Commit #{commit_sha} missing expected file changes: #{missing.join(", ")}. Changed files: #{changed_files.join(", ")}"
      end
      unless extra.empty?
        raise "Commit #{commit_sha} included unexpected files: #{extra.join(", ")}. Expected: #{expected_paths.join(", ")}"
      end

      with_token_remote do |remote|
        push_output, push_status = @repo.push(branch, remote: remote)
        unless push_status.success?
          raise "Failed to push branch #{branch} to #{remote}: #{push_output}"
        end
      end

      return :pushed if delivery == "push"

      client = GitHubClient.new(token: @github_token, repo_slug: @repo_slug)
      remote_head = client.branch_head_sha(branch)
      if remote_head.nil? || remote_head != commit_sha
        raise "Remote branch #{branch} does not point to commit #{commit_sha}. Found: #{remote_head || "none"}"
      end

      created_pr = client.create_pull_request(
        head: branch,
        title: commit_content["pr_title"],
        body: commit_content["pr_description"]
      )
      unless created_pr && created_pr["number"]
        raise "Pull request creation did not return a PR number."
      end

      existing_pr = client.pull_request_for_branch(branch)
      unless existing_pr && existing_pr["number"] == created_pr["number"]
        raise "Pull request for branch #{branch} not found after creation."
      end

      :ok
    end

    private

    def build_engine
      case @engine_name.downcase
      when "chatgpt"
        Engines::ChatGPT.new(api_token: @api_token, model: @model, retries: @retries)
      else
        raise ArgumentError, "Unknown engine: #{@engine_name}"
      end
    end

    def delivery_method
      normalized = @delivery_method.to_s.strip.downcase
      return normalized if %w[pull_request push].include?(normalized)

      raise ArgumentError, "Unknown delivery method: #{@delivery_method}"
    end

    def translate_strings(engine, requests)
      translations = Hash.new { |hash, key| hash[key] = {} }
      failures = {}

      requests.each do |key, request|
        value = request[:value]
        locales = request[:locales]
        next unless value.is_a?(String)

        result = engine.get_translations(value, locales)
        result_translations = result["translations"] || {}
        result_errors = result["errors"] || {}

        locales.each do |locale|
          translation = result_translations[locale]
          if translation.is_a?(String) && !translation.strip.empty?
            translations[locale][key] = translation
            next
          end

          reason = result_errors[locale] || result_errors["_request"] || "no translation returned"
          failures[key] ||= {}
          failures[key][locale] = reason
        end
      end

      unless failures.empty?
        puts "Translation failures: #{JSON.pretty_generate(failures)}"
        raise "Translation failures detected"
      end

      translations
    end

    def apply_translations(translations, root_key)
      updated_paths = []
      translations.each do |locale, values|
        next if locale == source_locale

        target_path = LocaleFile.target_path_for(@source_file, locale)
        format = target_path.end_with?(".json") ? :json : :yaml

        data = if File.exist?(target_path)
                 content = File.read(target_path)
                 format == :json ? JSON.parse(content) : (YAML.safe_load(content, aliases: true) || {})
               else
                 {}
               end

        locale_file = LocaleFile.new(data, locale_hint: locale)
        locale_file = ensure_root(locale_file, locale, root_key)

        values.each do |key, translation|
          locale_file.set_value(key, translation)
        end

        serialized = locale_file.to_serialized(format)
        File.write(target_path, serialized)
        updated_paths << target_path
      end

      updated_paths
    end

    def ensure_root(locale_file, locale, source_root)
      return locale_file if locale_file.root_key || source_root.nil?

      data = { locale => locale_file.data }
      LocaleFile.new(data, locale_hint: locale)
    end

    def build_translation_requests(result)
      source_strings = result.source_strings || {}
      changed_strings = result.changed_strings || {}
      changed_keys = Set.new(changed_strings.keys)
      missing_locales_by_key = Hash.new { |hash, key| hash[key] = [] }

      target_locales.each do |locale|
        target_path = LocaleFile.target_path_for(@source_file, locale)
        target_strings = load_flattened_strings(target_path, locale)
        source_strings.each_key do |key|
          next if changed_keys.include?(key)
          next if target_strings.key?(key)

          missing_locales_by_key[key] << locale
        end
      end

      requests = {}
      changed_strings.each do |key, value|
        requests[key] = { value: value, locales: target_locales }
      end

      missing_locales_by_key.each do |key, locales|
        value = source_strings[key]
        next unless value.is_a?(String)

        requests[key] = { value: value, locales: locales }
      end

      [requests, missing_locales_by_key.keys]
    end

    def load_flattened_strings(path, locale)
      return {} unless File.exist?(path)

      content = File.read(path)
      data = if path.end_with?(".json")
               JSON.parse(content)
             else
               YAML.safe_load(content, aliases: true) || {}
             end

      LocaleFile.new(data, locale_hint: locale).flattened_strings
    end

    def source_locale
      @source_locale ||= LocaleFile.locale_from_path(@source_file)
    end

    def target_locales
      @target_locales ||= @target_languages.reject { |locale| locale == source_locale }
    end

    def with_token_remote
      remote = "origin"
      url_output, status = @repo.capture("git remote get-url origin")
      return yield(remote) unless status.success?

      url = url_output.strip
      if url.start_with?("https://")
        token_url = url.sub("https://", "https://x-access-token:#{@github_token}@")
        remote = "token"
        @repo.capture("git remote add #{remote} #{token_url}")
      end

      yield(remote)
    ensure
      @repo.capture("git remote remove token")
    end
  end
end
