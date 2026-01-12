# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Prism::Translator do
  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
  end

  def build_translator(source_file:, target_languages:, delivery_method: 'pull_request', llm_commit_messages: false)
    described_class.new(
      repo: instance_double(Prism::GitRepo),
      commit: 'sha',
      source_file: source_file,
      target_languages: target_languages,
      engine: 'ChatGPT',
      api_token: 'token',
      model: 'gpt-5-mini',
      author_name: 'TheStranjer',
      author_email: 'thestranjer@protonmail.com',
      github_token: 'gh',
      repo_slug: 'org/repo',
      delivery_method: delivery_method,
      llm_commit_messages: llm_commit_messages
    )
  end

  it 'requests translations for modified keys across all locales and backfills missing locales only' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello there', 'title' => 'App', 'subtitle' => 'Sub' })
      write_json(File.join(dir, 'locales/fr.json'),
                 { 'greeting' => 'Bonjour', 'title' => 'App fr', 'subtitle' => 'Sub fr' })
      write_json(File.join(dir, 'locales/de.json'), { 'greeting' => 'Hallo', 'subtitle' => 'Unter' })

      translator = build_translator(source_file: source_path, target_languages: %w[fr de])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello there' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: { 'greeting' => 'Hello there' },
        source_strings: { 'greeting' => 'Hello there', 'title' => 'App', 'subtitle' => 'Sub' }
      )

      requests, backfilled = translator.send(:build_translation_requests, result)

      expect(requests.keys).to contain_exactly('greeting', 'title')
      expect(requests['greeting'][:locales]).to eq(%w[fr de])
      expect(requests['title'][:locales]).to eq(['de'])
      expect(backfilled).to contain_exactly('title')
      expect(requests).not_to have_key('subtitle')
    end
  end

  it 'backfills all keys for missing locale files even without source changes' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello', 'title' => 'App' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour', 'title' => 'Appli' })

      translator = build_translator(source_file: source_path, target_languages: %w[fr es])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { 'greeting' => 'Hello', 'title' => 'App' }
      )

      requests, backfilled = translator.send(:build_translation_requests, result)

      expect(requests.keys).to contain_exactly('greeting', 'title')
      expect(requests['greeting'][:locales]).to eq(['es'])
      expect(requests['title'][:locales]).to eq(['es'])
      expect(backfilled).to contain_exactly('greeting', 'title')
    end
  end

  it 'skips source locale when building translation requests' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello', 'title' => 'App' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour' })

      translator = build_translator(source_file: source_path, target_languages: %w[en fr])
      result = Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: { 'greeting' => 'Hello' },
        source_strings: { 'greeting' => 'Hello', 'title' => 'App' }
      )

      requests, backfilled = translator.send(:build_translation_requests, result)

      expect(requests.keys).to contain_exactly('greeting', 'title')
      expect(requests['greeting'][:locales]).to eq(['fr'])
      expect(requests['title'][:locales]).to eq(['fr'])
      expect(backfilled).to contain_exactly('title')
    end
  end

  it 'does not write translations back into the source locale file' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour' })

      translator = build_translator(source_file: source_path, target_languages: %w[en fr])
      original_source = File.read(source_path)
      translations = {
        'en' => { 'greeting' => 'Hi' },
        'fr' => { 'greeting' => 'Salut' }
      }

      updated_paths = translator.send(:apply_translations, translations, nil)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(File.read(source_path)).to eq(original_source)
    end
  end

  it 'excludes files from updated_paths when translations match existing values' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello', 'title' => 'App' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour', 'title' => 'Appli' })
      write_json(File.join(dir, 'locales/de.json'), { 'greeting' => 'Hallo', 'title' => 'Anwendung' })

      translator = build_translator(source_file: source_path, target_languages: %w[fr de])
      original_fr = File.read(File.join(dir, 'locales/fr.json'))
      File.read(File.join(dir, 'locales/de.json'))

      translations = {
        'fr' => { 'greeting' => 'Bonjour', 'title' => 'Appli' },
        'de' => { 'greeting' => 'Hallo', 'title' => 'App' }
      }

      updated_paths = translator.send(:apply_translations, translations, nil)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/de.json'))
      expect(File.read(File.join(dir, 'locales/fr.json'))).to eq(original_fr)
    end
  end

  it 'pushes directly to the current branch with LLM commit message when llm_commit_messages is true' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      translator = build_translator(source_file: source_path, target_languages: ['fr'], delivery_method: 'push',
                                    llm_commit_messages: true)
      repo = translator.instance_variable_get(:@repo)

      diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: {}
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

      engine = instance_double(Prism::Engines::ChatGPT)
      allow(engine).to receive(:generate_commit_content).with(
        source_commit_diff: "commit sha\n\nOriginal changes",
        staged_diff: 'diff --git a/locales/fr.json',
        delivery_method: 'push'
      ).and_return({
                     'commit_message' => 'Add French translations for greeting'
                   })
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      allow(repo).to receive(:set_identity)
      allow(repo).to receive(:current_branch).and_return('main')
      allow(repo).to receive(:add)
      allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
      allow(repo).to receive(:show_commit).with('sha').and_return("commit sha\n\nOriginal changes")
      allow(repo).to receive(:head_sha).and_return('old', 'new')
      allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
      allow(repo).to receive(:relative_path).and_return('locales/fr.json')
      allow(repo).to receive(:commit).with('Add French translations for greeting')
                 .and_return(['ok', instance_double(Process::Status, success?: true)])
      expect(repo).not_to receive(:checkout_new_branch)
      expect(repo).to receive(:push).with('main',
                                          remote: 'origin').and_return(['ok',
                                                                        instance_double(Process::Status,
                                                                                        success?: true)])
      expect(Prism::GitHubClient).not_to receive(:new)

      result = translator.run

      expect(result).to eq(:pushed)
    end
  end

  it 'pushes directly to the current branch with default commit message when llm_commit_messages is false' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      translator = build_translator(source_file: source_path, target_languages: ['fr'], delivery_method: 'push',
                                    llm_commit_messages: false)
      repo = translator.instance_variable_get(:@repo)

      diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: {}
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

      engine = instance_double(Prism::Engines::ChatGPT)
      expect(engine).not_to receive(:generate_commit_content)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      allow(repo).to receive(:set_identity)
      allow(repo).to receive(:current_branch).and_return('main')
      allow(repo).to receive(:add)
      allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
      allow(repo).to receive(:head_sha).and_return('old', 'new')
      allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
      allow(repo).to receive(:relative_path).and_return('locales/fr.json')
      allow(repo).to receive(:commit).with('Update translations').and_return(['ok',
                                                                              instance_double(Process::Status,
                                                                                              success?: true)])
      expect(repo).not_to receive(:checkout_new_branch)
      expect(repo).to receive(:push).with('main',
                                          remote: 'origin').and_return(['ok',
                                                                        instance_double(Process::Status,
                                                                                        success?: true)])
      expect(Prism::GitHubClient).not_to receive(:new)

      result = translator.run

      expect(result).to eq(:pushed)
    end
  end

  it 'creates a pull request with LLM commit message when llm_commit_messages is true' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      translator = build_translator(source_file: source_path, target_languages: ['fr'],
                                    delivery_method: 'pull_request', llm_commit_messages: true)
      repo = translator.instance_variable_get(:@repo)

      diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: {}
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

      engine = instance_double(Prism::Engines::ChatGPT)
      allow(engine).to receive(:generate_commit_content).with(
        source_commit_diff: "commit sha\n\nOriginal changes",
        staged_diff: 'diff --git a/locales/fr.json',
        delivery_method: 'pull_request'
      ).and_return({
                     'commit_message' => 'Add French translations for greeting',
                     'pr_title' => 'Update translations for greeting changes',
                     'pr_description' => 'This PR adds French translations for the greeting field.'
                   })
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      allow(repo).to receive(:set_identity)
      allow(repo).to receive(:add)
      allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
      allow(repo).to receive(:show_commit).with('sha').and_return("commit sha\n\nOriginal changes")
      allow(repo).to receive(:head_sha).and_return('old', 'new')
      allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
      allow(repo).to receive(:relative_path).and_return('locales/fr.json')
      allow(repo).to receive(:commit).with('Add French translations for greeting')
                 .and_return(['ok', instance_double(Process::Status, success?: true)])
      expect(repo).to receive(:checkout_new_branch).with(a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}))
      expect(repo).to receive(:push).with(a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}), remote: 'origin')
                                    .and_return(['ok', instance_double(Process::Status, success?: true)])

      client = instance_double(Prism::GitHubClient)
      expect(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
      allow(client).to receive(:branch_head_sha).and_return('new')
      expect(client).to receive(:create_pull_request).with(
        head: a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}),
        title: 'Update translations for greeting changes',
        body: 'This PR adds French translations for the greeting field.'
      ).and_return({ 'number' => 12 })
      allow(client).to receive(:pull_request_for_branch).and_return({ 'number' => 12 })

      result = translator.run

      expect(result).to eq(:ok)
    end
  end

  it 'creates a pull request with default commit message when llm_commit_messages is false' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      translator = build_translator(source_file: source_path, target_languages: ['fr'],
                                    delivery_method: 'pull_request', llm_commit_messages: false)
      repo = translator.instance_variable_get(:@repo)

      diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: { 'greeting' => 'Hello' },
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: {}
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

      engine = instance_double(Prism::Engines::ChatGPT)
      expect(engine).not_to receive(:generate_commit_content)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      allow(repo).to receive(:set_identity)
      allow(repo).to receive(:add)
      allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
      allow(repo).to receive(:head_sha).and_return('old', 'new')
      allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
      allow(repo).to receive(:relative_path).and_return('locales/fr.json')
      allow(repo).to receive(:commit).with('Update translations').and_return(['ok',
                                                                              instance_double(Process::Status,
                                                                                              success?: true)])
      expect(repo).to receive(:checkout_new_branch).with(a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}))
      expect(repo).to receive(:push).with(a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}), remote: 'origin')
                                    .and_return(['ok', instance_double(Process::Status, success?: true)])

      client = instance_double(Prism::GitHubClient)
      expect(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
      allow(client).to receive(:branch_head_sha).and_return('new')
      expect(client).to receive(:create_pull_request).with(
        head: a_string_matching(%r{\Ai18n/auto-translate-\d{14}\z}),
        title: 'Update translations',
        body: 'Automated translation updates.'
      ).and_return({ 'number' => 12 })
      allow(client).to receive(:pull_request_for_branch).and_return({ 'number' => 12 })

      result = translator.run

      expect(result).to eq(:ok)
    end
  end
end
