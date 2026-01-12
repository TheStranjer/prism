# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Prism::Translator do
  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
  end

  def build_translator(source_file:, target_languages:)
    described_class.new(
      repo: instance_double(Prism::GitRepo),
      commit: "sha",
      source_file: source_file,
      target_languages: target_languages,
      engine: "chatgpt",
      api_token: "token",
      model: "model",
      author_name: "Test",
      author_email: "test@example.com",
      github_token: "gh",
      repo_slug: "org/repo"
    )
  end

  it "requests translations for modified keys across all locales and backfills missing locales only" do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "locales/en.json")
      write_json(source_path, { "greeting" => "Hello there", "title" => "App", "subtitle" => "Sub" })
      write_json(File.join(dir, "locales/fr.json"), { "greeting" => "Bonjour", "title" => "App fr", "subtitle" => "Sub fr" })
      write_json(File.join(dir, "locales/de.json"), { "greeting" => "Hallo", "subtitle" => "Unter" })

      translator = build_translator(source_file: source_path, target_languages: %w[fr de])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: { "greeting" => "Hello there" },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: { "greeting" => "Hello there" },
        source_strings: { "greeting" => "Hello there", "title" => "App", "subtitle" => "Sub" }
      )

      requests, backfilled = translator.send(:build_translation_requests, result)

      expect(requests.keys).to contain_exactly("greeting", "title")
      expect(requests["greeting"][:locales]).to eq(%w[fr de])
      expect(requests["title"][:locales]).to eq(["de"])
      expect(backfilled).to contain_exactly("title")
      expect(requests).not_to have_key("subtitle")
    end
  end

  it "backfills all keys for missing locale files even without source changes" do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "locales/en.json")
      write_json(source_path, { "greeting" => "Hello", "title" => "App" })
      write_json(File.join(dir, "locales/fr.json"), { "greeting" => "Bonjour", "title" => "Appli" })

      translator = build_translator(source_file: source_path, target_languages: %w[fr es])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { "greeting" => "Hello", "title" => "App" }
      )

      requests, backfilled = translator.send(:build_translation_requests, result)

      expect(requests.keys).to contain_exactly("greeting", "title")
      expect(requests["greeting"][:locales]).to eq(["es"])
      expect(requests["title"][:locales]).to eq(["es"])
      expect(backfilled).to contain_exactly("greeting", "title")
    end
  end

  it "formats PR body with added and modified fields separated" do
    Dir.mktmpdir do |dir|
      translator = build_translator(source_file: File.join(dir, "locales/en.json"), target_languages: ["fr"])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: { "greeting" => "Hi", "title" => "App" },
        source_locale_root: nil,
        added_strings: { "title" => "App" },
        modified_strings: { "greeting" => "Hi" },
        source_strings: {}
      )

      body = translator.send(:pull_request_body, result, ["subtitle"])
      lines = body.split("\n")

      expect(lines).to include("Added fields:")
      expect(lines).to include("- subtitle", "- title")
      expect(lines).to include("Modified fields:")
      expect(lines).to include("- greeting")
    end
  end

  it "excludes modified keys from added list in PR body" do
    Dir.mktmpdir do |dir|
      translator = build_translator(source_file: File.join(dir, "locales/en.json"), target_languages: ["fr"])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: { "greeting" => "Hi" },
        source_locale_root: nil,
        added_strings: { "greeting" => "Hi" },
        modified_strings: { "greeting" => "Hi" },
        source_strings: {}
      )

      body = translator.send(:pull_request_body, result, ["greeting"])
      lines = body.split("\n")

      expect(lines).to include("Added fields:")
      expect(lines).to include("- None")
      expect(lines).to include("Modified fields:")
      expect(lines).to include("- greeting")
    end
  end
end
