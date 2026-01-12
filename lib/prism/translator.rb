# frozen_string_literal: true

require "json"
require "yaml"

module Prism
  class Translator
    def initialize(repo:, commit:, source_file:, target_languages:, engine:, api_token:, model:, author_name:, author_email:, github_token:, repo_slug:, retries: 5)
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
    end

    def run
      diff = DiffExaminer.new(repo: @repo, commit: @commit, source_file: @source_file)
      return :unchanged if diff.unchanged?

      result = diff.changed_strings
      return :no_strings if result.changed_strings.empty?

      engine = build_engine
      puts "Changed strings: #{JSON.pretty_generate(result.changed_strings)}"
      translations = translate_strings(engine, result.changed_strings)

      puts "Translations: #{JSON.pretty_generate(translations)}"

      updated_paths = apply_translations(translations, result.source_locale_root)
      return :no_updates if updated_paths.empty?
      puts "Updated locale files: #{JSON.pretty_generate(updated_paths)}"

      branch = "i18n/auto-translate-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
      @repo.set_identity(@author_name, @author_email)
      @repo.checkout_new_branch(branch)
      @repo.add(updated_paths)
      @repo.commit("chore(i18n): auto-translate updated strings")

      with_token_remote do |remote|
        @repo.push(branch, remote: remote)
      end

      client = GitHubClient.new(token: @github_token, repo_slug: @repo_slug)
      client.create_pull_request(
        head: branch,
        title: "Auto-translate i18n updates",
        body: "Automated translations for #{@source_file} (#{@commit})."
      )

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

    def translate_strings(engine, changed_strings)
      translations = Hash.new { |hash, key| hash[key] = {} }
      failures = {}

      changed_strings.each do |key, value|
        next unless value.is_a?(String)

        result = engine.get_translations(value, @target_languages)
        result_translations = result["translations"] || {}
        result_errors = result["errors"] || {}

        @target_languages.each do |locale|
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
