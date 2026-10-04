# frozen_string_literal: true

require 'json'
require 'yaml'

module Prism
  class Translator
    INVALID_LLM_TOKEN_ERROR = 'LLM API token validation failed. Please check your API token is valid and ' \
                              'has access to completions.'

    def initialize(repo:, commit:, source_file:, target_languages:, engine:, api_token:, model:,
                   author_name:, author_email:, github_token:, repo_slug:, retries: 5,
                   delivery_method: 'pull_request', llm_commit_messages: false)
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
      @llm_commit_messages = llm_commit_messages
    end

    def run
      diff = DiffExaminer.new(repo: @repo, commit: @commit, source_file: @source_file)
      unchanged = diff.unchanged?

      engine = build_engine
      result = diff.changed_strings
      requests, backfilled_keys = build_translation_requests(result)
      write_plan = write_plan_by_locale(requests)
      stale_keys = stale_keys_by_locale(result.source_strings || {}, result.source_locale_root, write_plan)
      return :unchanged if unchanged && requests.empty? && backfilled_keys.empty? && stale_keys.empty?
      return :no_strings if requests.empty? && stale_keys.empty?

      validate_tokens(engine)

      Logging.log("Changed strings: #{JSON.pretty_generate(result.changed_strings)}")
      Logging.log("Backfilled strings: #{JSON.pretty_generate(backfilled_keys.sort)}") unless backfilled_keys.empty?
      Logging.log("Stale keys: #{JSON.pretty_generate(stale_keys.sort.to_h)}") unless stale_keys.empty?

      translations = translate_strings(engine, requests)

      Logging.log("Translations: #{JSON.pretty_generate(translations)}")

      updated_paths = apply_translations(translations, result, stale_keys)
      return :no_updates if updated_paths.empty?

      Logging.log("Updated locale files: #{JSON.pretty_generate(updated_paths)}")

      delivery = delivery_method
      branch = translation_branch(delivery)

      @repo.set_identity(@author_name, @author_email)
      @repo.checkout_new_branch(branch) if delivery == 'pull_request'
      @repo.add(updated_paths)

      staged_diff = @repo.staged_diff
      raise 'Failed to get staged diff' if staged_diff.nil?

      commit_content = build_commit_content(engine, delivery, staged_diff)
      Logging.log("Generated commit content: #{JSON.pretty_generate(commit_content)}")

      before_head = @repo.head_sha
      commit_output, commit_status = @repo.commit(commit_content['commit_message'])
      raise "Failed to create commit: #{commit_output}" unless commit_status.success?

      commit_sha = @repo.head_sha
      raise "Commit did not advance HEAD. Output: #{commit_output.strip}" if head_unchanged?(commit_sha, before_head)

      expected_paths = updated_paths.map { |path| @repo.relative_path(path).sub(%r{\A\./}, '') }.uniq
      changed_files = @repo.changed_files(commit_sha)
      missing = expected_paths - changed_files
      extra = changed_files - expected_paths
      raise missing_files_error(commit_sha, missing, changed_files) unless missing.empty?
      raise unexpected_files_error(commit_sha, extra, expected_paths) unless extra.empty?

      with_token_remote do |remote|
        push_output, push_status = @repo.push(branch, remote: remote)
        raise "Failed to push branch #{branch} to #{remote}: #{push_output}" unless push_status.success?
      end

      return :pushed if delivery == 'push'

      client = GitHubClient.new(token: @github_token, repo_slug: @repo_slug)
      remote_head = client.branch_head_sha(branch)
      raise remote_branch_error(branch, commit_sha, remote_head) if remote_head.nil? || remote_head != commit_sha

      created_pr = client.create_pull_request(
        head: branch,
        title: commit_content['pr_title'],
        body: commit_content['pr_description']
      )
      raise 'Pull request creation did not return a PR number.' unless created_pr && created_pr['number']

      existing_pr = client.pull_request_for_branch(branch)
      raise pull_request_missing_error(branch) unless pull_request_found?(existing_pr, created_pr)

      :ok
    end

    private

    def build_engine
      case @engine_name.downcase
      when 'chatgpt'
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

    def translation_branch(delivery)
      return pull_request_branch if delivery == 'pull_request'

      branch = @repo.current_branch
      raise 'Cannot push translation commit because current branch is detached.' if detached_push?(delivery, branch)

      branch
    end

    def pull_request_branch
      "i18n/auto-translate-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
    end

    def detached_push?(delivery, branch)
      delivery == 'push' && (branch.nil? || branch.empty? || branch == 'HEAD')
    end

    def build_commit_content(engine, delivery, staged_diff)
      return default_commit_content(delivery) unless @llm_commit_messages

      source_commit_diff = @repo.show_commit(@commit)
      raise 'Failed to get source commit diff' if source_commit_diff.nil?

      engine.generate_commit_content(
        source_commit_diff: source_commit_diff,
        staged_diff: staged_diff,
        delivery_method: delivery
      )
    end

    def default_commit_content(delivery)
      content = { 'commit_message' => 'Update translations' }
      return with_pull_request_details(content) if delivery == 'pull_request'

      content
    end

    def with_pull_request_details(content)
      content.merge(
        'pr_title' => 'Update translations',
        'pr_description' => 'Automated translation updates.'
      )
    end

    def translate_strings(engine, requests)
      translations = Hash.new { |hash, key| hash[key] = {} }
      failures = {}

      requests.each do |key, request|
        value = request[:value]
        locales = request[:locales]
        next unless value.is_a?(String)

        result = engine.get_translations(value, locales)
        result_translations = result['translations'] || {}
        result_errors = result['errors'] || {}

        locales.each do |locale|
          translation = result_translations[locale]
          if usable_translation?(translation)
            translations[locale][key] = translation
          else
            record_failure(failures, key, locale, result_errors)
          end
        end
      end

      report_failures!(failures) unless failures.empty?

      translations
    end

    def usable_translation?(translation)
      translation.is_a?(String) && !translation.strip.empty?
    end

    def record_failure(failures, key, locale, errors)
      failures[key] ||= {}
      failures[key][locale] = errors[locale] || errors['_request'] || 'no translation returned'
    end

    def report_failures!(failures)
      Logging.log("Translation failures: #{JSON.pretty_generate(failures)}")
      raise 'Translation failures detected'
    end

    def head_unchanged?(commit_sha, before_head)
      commit_sha.nil? || commit_sha == before_head
    end

    def missing_files_error(commit_sha, missing, changed_files)
      "Commit #{commit_sha} missing expected file changes: #{missing.join(', ')}. " \
        "Changed files: #{changed_files.join(', ')}"
    end

    def unexpected_files_error(commit_sha, extra, expected_paths)
      "Commit #{commit_sha} included unexpected files: #{extra.join(', ')}. " \
        "Expected: #{expected_paths.join(', ')}"
    end

    def remote_branch_error(branch, commit_sha, remote_head)
      "Remote branch #{branch} does not point to commit #{commit_sha}. Found: #{remote_head || 'none'}"
    end

    def pull_request_missing_error(branch)
      "Pull request for branch #{branch} not found after creation."
    end

    def pull_request_found?(existing_pr, created_pr)
      return false unless existing_pr

      existing_pr['number'] == created_pr['number']
    end

    def apply_translations(translations, result, stale_keys = nil)
      root_key = result.source_locale_root
      source_strings = result.source_strings || {}
      stale_keys ||= stale_keys_by_locale(source_strings, root_key, translated_keys_by_locale(translations))
      updated_paths = []
      target_locales.each do |locale|
        target_path = LocaleFile.target_path_for(@source_file, locale)
        format = target_path.end_with?('.json') ? :json : :yaml

        data = load_target_data(target_path, format)

        locale_file = LocaleFile.new(data, locale_hint: locale, source_root_key: root_key)
        locale_file = ensure_root(locale_file, locale, root_key)

        existing_strings = locale_file.flattened_strings
        has_changes = false

        translations_for_locale = translations[locale] || {}
        translations_for_locale.each do |key, translation|
          has_changes = true if existing_strings[key] != translation
          locale_file.set_value(key, translation)
        end

        has_changes = true if prune_stale_keys(locale_file, stale_keys[locale] || [])

        next unless has_changes

        serialized = locale_file.to_serialized(format)
        File.write(target_path, serialized)
        updated_paths << target_path
      end

      updated_paths
    end

    def prune_stale_keys(locale_file, stale_keys)
      removed = false
      stale_keys.each do |key|
        removed = true if locale_file.remove_value(key)
      end
      removed
    end

    def stale_keys_by_locale(source_strings, source_root = nil, keys_written_by_locale = {})
      target_locales.each_with_object({}) do |locale, stale|
        target_path = LocaleFile.target_path_for(@source_file, locale)
        target_strings = load_flattened_strings(target_path, locale, source_root)
        keys = keys_to_prune(target_strings.keys, source_strings.keys, keys_written_by_locale[locale] || [])
        stale[locale] = keys unless keys.empty?
      end
    end

    def keys_to_prune(target_keys, source_keys, keys_written_this_pass)
      (target_keys - source_keys).reject { |key| rebuilt_by_writes?(key, keys_written_this_pass) }
    end

    def rebuilt_by_writes?(key, keys_written_this_pass)
      keys_written_this_pass.any? { |written| written.start_with?("#{key}.") }
    end

    def write_plan_by_locale(requests)
      target_locales.to_h do |locale|
        [locale, requests.filter_map { |key, request| key if request[:locales].include?(locale) }]
      end
    end

    def translated_keys_by_locale(translations)
      target_locales.to_h { |locale| [locale, (translations[locale] || {}).keys] }
    end

    def ensure_root(locale_file, locale, source_root)
      return locale_file if locale_file.root_key || source_root.nil?

      data = { locale => locale_file.data }
      LocaleFile.new(data, locale_hint: locale)
    end

    def build_translation_requests(result)
      source_strings = result.source_strings || {}
      source_root = result.source_locale_root
      changed_strings = result.changed_strings || {}
      changed_keys = Set.new(changed_strings.keys)
      missing_locales_by_key = Hash.new { |hash, key| hash[key] = [] }

      target_locales.each do |locale|
        target_path = LocaleFile.target_path_for(@source_file, locale)
        target_strings = load_flattened_strings(target_path, locale, source_root)
        source_strings.each_key do |key|
          next if changed_keys.include?(key)
          next if target_strings.key?(key)
          next if exclusions_handler.excluded?(key, locale)

          missing_locales_by_key[key] << locale
        end
      end

      requests = {}
      changed_strings.each do |key, value|
        locales = target_locales.reject { |locale| exclusions_handler.excluded?(key, locale) }
        next if locales.empty?

        requests[key] = { value: value, locales: locales }
      end

      backfilled_keys = []
      missing_locales_by_key.each do |key, locales|
        value = source_strings[key]
        next unless value.is_a?(String)

        requests[key] = { value: value, locales: locales }
        backfilled_keys << key
      end

      [requests, backfilled_keys]
    end

    def load_target_data(target_path, format)
      return {} unless File.exist?(target_path)

      content = File.read(target_path)
      format == :json ? JSON.parse(content) : (YAML.safe_load(content, aliases: true) || {})
    end

    def load_flattened_strings(path, locale, source_root = nil)
      return {} unless File.exist?(path)

      content = File.read(path)
      data = if path.end_with?('.json')
               JSON.parse(content)
             else
               YAML.safe_load(content, aliases: true) || {}
             end

      LocaleFile.new(data, locale_hint: locale, source_root_key: source_root).flattened_strings
    end

    def source_locale
      @source_locale ||= LocaleFile.locale_from_path(@source_file)
    end

    def target_locales
      @target_locales ||= @target_languages.reject { |locale| locale == source_locale }
    end

    def exclusions_handler
      @exclusions_handler ||= ExclusionsHandler.new(source_file: @source_file)
    end

    def with_token_remote
      url_output, status = @repo.capture('git remote get-url origin')
      return yield('origin') unless status.success?

      yield(tokenized_remote(url_output.strip))
    ensure
      @repo.capture('git remote remove token')
    end

    def tokenized_remote(url)
      return 'origin' unless url.start_with?('https://')

      token_url = url.sub('https://', "https://x-access-token:#{@github_token}@")
      @repo.capture("git remote add token #{token_url}")
      'token'
    end

    def validate_tokens(engine)
      raise INVALID_LLM_TOKEN_ERROR unless engine.validate_token

      client = GitHubClient.new(token: @github_token, repo_slug: @repo_slug)
      result = client.validate_token_with_reason(delivery_method: delivery_method)

      return if result[:valid]

      message = case result[:reason]
                when :missing
                  'GitHub token is missing or empty.'
                when :expired
                  'GitHub token is expired or invalid.'
                when :no_access
                  "GitHub token does not have access to repository #{@repo_slug}."
                when :no_push_permission
                  "GitHub token does not have push permission for repository #{@repo_slug}."
                when :no_pull_request_permission
                  "GitHub token does not have permission to create pull requests for repository #{@repo_slug}."
                else
                  "GitHub token validation failed: #{result[:message] || 'unknown error'}"
                end

      raise message
    end
  end
end
