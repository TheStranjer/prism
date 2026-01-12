# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"

RSpec.describe Prism::DiffExaminer do
  def init_repo
    Dir.mktmpdir do |dir|
      system("git init -q", chdir: dir)
      system("git config user.email test@example.com", chdir: dir)
      system("git config user.name Test", chdir: dir)
      yield dir
    end
  end

  def commit_file(dir, path, content, message)
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), content)
    system("git add #{path}", chdir: dir)
    system("git commit -q -m \"#{message}\"", chdir: dir)
    sha = `git -C #{dir} rev-parse HEAD`.strip
    [sha, File.join(dir, path)]
  end

  it "detects unchanged source file" do
    init_repo do |dir|
      commit_file(dir, "locales/en.json", JSON.pretty_generate({ "hello" => "Hello" }), "init")
      sha, = commit_file(dir, "README.md", "noop", "touch")
      repo = Prism::GitRepo.new(dir)
      examiner = described_class.new(repo: repo, commit: sha, source_file: "locales/en.json")
      expect(examiner.unchanged?).to be true
    end
  end

  it "extracts changed keys from JSON without root locale" do
    init_repo do |dir|
      commit_file(dir, "locales/en.json", JSON.pretty_generate({ "greeting" => "Hello", "title" => "App" }), "init")
      sha, = commit_file(dir, "locales/en.json", JSON.pretty_generate({ "greeting" => "Hello there", "title" => "App" }), "update")

      repo = Prism::GitRepo.new(dir)
      examiner = described_class.new(repo: repo, commit: sha, source_file: "locales/en.json")
      result = examiner.changed_strings

      expect(result.changed_strings).to eq({ "greeting" => "Hello there" })
      expect(result.source_locale_root).to be_nil
    end
  end

  it "extracts changed keys from YAML with root locale" do
    init_repo do |dir|
      initial = { "en" => { "home" => { "title" => "Home" } } }
      updated = { "en" => { "home" => { "title" => "Homepage" } } }
      commit_file(dir, "locales/en.yml", YAML.dump(initial), "init")
      sha, = commit_file(dir, "locales/en.yml", YAML.dump(updated), "update")

      repo = Prism::GitRepo.new(dir)
      examiner = described_class.new(repo: repo, commit: sha, source_file: "locales/en.yml")
      result = examiner.changed_strings

      expect(result.changed_strings).to eq({ "home.title" => "Homepage" })
      expect(result.source_locale_root).to eq("en")
    end
  end
end
