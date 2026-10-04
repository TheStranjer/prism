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

  def build_translator(source_file:, target_languages:, delivery_method: 'pull_request', llm_commit_messages: false,
                       api_token: 'token', github_token: 'gh', engine: 'ChatGPT', retries: 5, repo: nil)
    described_class.new(
      repo: repo || instance_double(Prism::GitRepo),
      commit: 'sha',
      source_file: source_file,
      target_languages: target_languages,
      engine: engine,
      api_token: api_token,
      model: 'gpt-5-mini',
      author_name: 'TheStranjer',
      author_email: 'thestranjer@protonmail.com',
      github_token: github_token,
      repo_slug: 'org/repo',
      retries: retries,
      delivery_method: delivery_method,
      llm_commit_messages: llm_commit_messages
    )
  end

  def repo_of(translator)
    translator.instance_variable_get(:@repo)
  end

  def stub_status(success)
    instance_double(Process::Status, success?: success)
  end

  def engine_validating(valid)
    engine = instance_double(Prism::Engines::ChatGPT)
    allow(engine).to receive(:validate_token).and_return(valid)
    engine
  end

  # A diff with one changed key, so every guarded run below has something to translate.
  def changed_greeting_diff
    instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
      changed_strings: { 'greeting' => 'Hello' },
      source_locale_root: nil,
      added_strings: {},
      modified_strings: { 'greeting' => 'Hello' },
      source_strings: { 'greeting' => 'Hello' }
    ))
  end

  # Stubs a run from token validation through a committed locales/fr.json, so examples
  # can drive the guards that follow: commit verification, push and delivery.
  def stub_translations_committed(translator, updated_path)
    engine = instance_double(Prism::Engines::ChatGPT)
    allow(engine).to receive(:validate_token).and_return(true)
    allow(translator).to receive(:build_engine).and_return(engine)
    allow(translator).to receive(:build_translation_requests)
                     .and_return([{ 'greeting' => { value: 'Hello', locales: ['fr'] } }, []])
    allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
    allow(translator).to receive(:apply_translations).and_return([updated_path])
    allow(translator).to receive(:with_token_remote).and_yield('origin')

    repo = repo_of(translator)
    allow(repo).to receive(:set_identity)
    allow(repo).to receive(:current_branch).and_return('main')
    allow(repo).to receive(:add)
    allow(repo).to receive(:checkout_new_branch)
    allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
    allow(repo).to receive(:show_commit).and_return("commit sha\n\nOriginal changes")
    allow(repo).to receive(:head_sha).and_return('before-sha', 'after-sha')
    allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
    allow(repo).to receive(:relative_path).and_return('locales/fr.json')
    allow(repo).to receive(:commit).and_return(['commit output', stub_status(true)])
    allow(repo).to receive(:push).and_return(['push output', stub_status(true)])
    repo
  end

  # One client double stands in for both GitHubClient builds of a run: token validation
  # and post-push verification. Examples override the calls they care about.
  def stub_github_client
    client = instance_double(Prism::GitHubClient)
    allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
    allow(client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })
    allow(client).to receive(:branch_head_sha).and_return('after-sha')
    allow(client).to receive(:create_pull_request).and_return({ 'number' => 12 })
    allow(client).to receive(:pull_request_for_branch).and_return({ 'number' => 12 })
    client
  end

  def logged_output
    Prism::Logging.output.string
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
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'greeting' => 'Hello' }
      )

      updated_paths = translator.send(:apply_translations, translations, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(File.read(source_path)).to eq(original_source)
      expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json')))).to eq({ 'greeting' => 'Salut' })
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
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'greeting' => 'Hello', 'title' => 'App' }
      )

      updated_paths = translator.send(:apply_translations, translations, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/de.json'))
      expect(File.read(File.join(dir, 'locales/fr.json'))).to eq(original_fr)
    end
  end

  it 'prunes entries missing from the source file while applying translations' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello', 'old' => { 'keep' => 'Keep' } })
      write_json(File.join(dir, 'locales/fr.json'),
                 { 'greeting' => 'Bonjour', 'gone' => 'Parti', 'old' => { 'deep' => 'Vieux', 'keep' => 'Garder' } })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'greeting' => 'Hello', 'old.keep' => 'Keep' }
      )

      updated_paths = translator.send(:apply_translations, { 'fr' => { 'greeting' => 'Salut' } }, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json'))))
        .to eq({ 'greeting' => 'Salut', 'old' => { 'keep' => 'Garder' } })
    end
  end

  it 'writes target files that only need stale entries removed' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour', 'gone' => 'Parti' })
      write_json(File.join(dir, 'locales/de.json'), { 'greeting' => 'Hallo' })

      translator = build_translator(source_file: source_path, target_languages: %w[fr de])
      original_de = File.read(File.join(dir, 'locales/de.json'))
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'greeting' => 'Hello' }
      )

      updated_paths = translator.send(:apply_translations, { 'fr' => { 'greeting' => 'Bonjour' } }, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json')))).to eq({ 'greeting' => 'Bonjour' })
      expect(File.read(File.join(dir, 'locales/de.json'))).to eq(original_de)
    end
  end

  it 'does not create target files when there are no translations and nothing to prune' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'greeting' => 'Hello' }
      )

      updated_paths = translator.send(:apply_translations, {}, result)

      expect(updated_paths).to be_empty
      expect(File.exist?(File.join(dir, 'locales/fr.json'))).to be(false)
    end
  end

  it 'creates missing target files rooted with the target locale' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'en' => { 'greeting' => 'Hello' } })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: 'en',
        source_strings: { 'greeting' => 'Hello' }
      )

      updated_paths = translator.send(:apply_translations, { 'fr' => { 'greeting' => 'Bonjour' } }, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json')))).to eq({ 'fr' => { 'greeting' => 'Bonjour' } })
    end
  end

  it 'prunes stale keys from YAML locale files' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.yml')
      fr_path = File.join(dir, 'locales/fr.yml')
      FileUtils.mkdir_p(File.dirname(source_path))
      File.write(source_path, YAML.dump({ 'en' => { 'greeting' => 'Hello' } }))
      File.write(fr_path, YAML.dump({ 'fr' => { 'greeting' => 'Bonjour', 'gone' => 'Parti' } }))

      translator = build_translator(source_file: source_path, target_languages: ['fr'])
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: 'en',
        source_strings: { 'greeting' => 'Hello' }
      )

      updated_paths = translator.send(:apply_translations, { 'fr' => {} }, result)

      expect(updated_paths).to contain_exactly(fr_path)
      expect(YAML.safe_load_file(fr_path)).to eq({ 'fr' => { 'greeting' => 'Bonjour' } })
    end
  end

  it 'overwrites a stale nested target subtree when the source key becomes a string' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'a' => 'Apple', 'keep' => 'Keep' })
      write_json(File.join(dir, 'locales/fr.json'), { 'a' => { 'b' => 'Ameise' }, 'keep' => 'Gardé' })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])
      result = Prism::DiffExaminer::Result.new(
        source_locale_root: nil,
        source_strings: { 'a' => 'Apple', 'keep' => 'Keep' }
      )

      updated_paths = translator.send(:apply_translations, { 'fr' => { 'a' => 'Pomme' } }, result)

      expect(updated_paths).to contain_exactly(File.join(dir, 'locales/fr.json'))
      expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json'))))
        .to eq({ 'a' => 'Pomme', 'keep' => 'Gardé' })
    end
  end

  it 'collects stale keys per target locale' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello', 'keep' => 'Kept' })
      write_json(File.join(dir, 'locales/fr.json'),
                 { 'greeting' => 'Bonjour', 'gone' => 'Parti', 'nested' => { 'deep' => 'Nid' } })
      write_json(File.join(dir, 'locales/de.json'), { 'greeting' => 'Hallo', 'keep' => 'Behalten' })

      translator = build_translator(source_file: source_path, target_languages: %w[fr de es])

      stale = translator.send(:stale_keys_by_locale, { 'greeting' => 'Hello', 'keep' => 'Kept' })

      expect(stale).to eq({ 'fr' => ['gone', 'nested.deep'] })
    end
  end

  it 'processes initial runs even when the source file is unchanged' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])

      diff = instance_double(Prism::DiffExaminer, unchanged?: true, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { 'greeting' => 'Hello' }
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

      engine = instance_double(Prism::Engines::ChatGPT)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:validate_tokens)
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([])

      result = translator.run

      expect(result).to eq(:no_updates)
    end
  end

  it 'returns unchanged when the source did not change and no target entries are stale' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour' })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])

      diff = instance_double(Prism::DiffExaminer, unchanged?: true, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { 'greeting' => 'Hello' }
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)
      allow(translator).to receive(:build_engine).and_return(instance_double(Prism::Engines::ChatGPT))
      expect(translator).not_to receive(:validate_tokens)

      expect(translator.run).to eq(:unchanged)
    end
  end

  it 'returns no_strings when there are no translation requests and nothing stale' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'locales/en.json')
      write_json(source_path, { 'greeting' => 'Hello' })
      write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour' })

      translator = build_translator(source_file: source_path, target_languages: ['fr'])

      diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { 'greeting' => 'Hello' }
      ))
      allow(Prism::DiffExaminer).to receive(:new).and_return(diff)
      allow(translator).to receive(:build_engine).and_return(instance_double(Prism::Engines::ChatGPT))
      expect(translator).not_to receive(:validate_tokens)

      expect(translator.run).to eq(:no_strings)
    end
  end

  describe 'pruning stale entries during a run' do
    def stub_push_delivery(translator)
      repo = translator.instance_variable_get(:@repo)

      engine = instance_double(Prism::Engines::ChatGPT)
      allow(engine).to receive(:validate_token).and_return(true)
      expect(engine).not_to receive(:get_translations)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      github_client = instance_double(Prism::GitHubClient)
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(github_client)
      allow(github_client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })

      allow(repo).to receive(:set_identity)
      allow(repo).to receive(:current_branch).and_return('main')
      allow(repo).to receive(:add)
      allow(repo).to receive(:staged_diff).and_return('diff --git a/locales/fr.json')
      allow(repo).to receive(:head_sha).and_return('old', 'new')
      allow(repo).to receive(:changed_files).and_return(['locales/fr.json'])
      allow(repo).to receive(:relative_path).and_return('locales/fr.json')
      allow(repo).to receive(:commit).with('Update translations')
                 .and_return(['ok', instance_double(Process::Status, success?: true)])
      expect(repo).to receive(:push).with('main',
                                          remote: 'origin').and_return(['ok',
                                                                        instance_double(Process::Status,
                                                                                        success?: true)])
    end

    def prune_diff(unchanged:)
      instance_double(Prism::DiffExaminer, unchanged?: unchanged, changed_strings: Prism::DiffExaminer::Result.new(
        changed_strings: {},
        source_locale_root: nil,
        added_strings: {},
        modified_strings: {},
        source_strings: { 'greeting' => 'Hello' }
      ))
    end

    it 'prunes target entries after a deletion-only source change' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })
        write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour', 'gone' => 'Parti' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'], delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(prune_diff(unchanged: false))
        stub_push_delivery(translator)

        expect(translator.run).to eq(:pushed)
        expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json')))).to eq({ 'greeting' => 'Bonjour' })
      end
    end

    it 'prunes target entries when the source file itself is unchanged' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })
        write_json(File.join(dir, 'locales/fr.json'), { 'greeting' => 'Bonjour', 'gone' => 'Parti' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'], delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(prune_diff(unchanged: true))
        stub_push_delivery(translator)

        expect(translator.run).to eq(:pushed)
        expect(JSON.parse(File.read(File.join(dir, 'locales/fr.json')))).to eq({ 'greeting' => 'Bonjour' })
      end
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
      allow(engine).to receive(:validate_token).and_return(true)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      github_client = instance_double(Prism::GitHubClient)
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(github_client)
      allow(github_client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })

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
      allow(engine).to receive(:validate_token).and_return(true)
      allow(translator).to receive(:build_engine).and_return(engine)
      allow(translator).to receive(:build_translation_requests).and_return([
                                                                             { 'greeting' => { value: 'Hello',
                                                                                               locales: ['fr'] } }, []
                                                                           ])
      allow(translator).to receive(:translate_strings).and_return({ 'fr' => { 'greeting' => 'Bonjour' } })
      allow(translator).to receive(:apply_translations).and_return([File.join(dir, 'locales/fr.json')])
      allow(translator).to receive(:with_token_remote).and_yield('origin')

      validation_client = instance_double(Prism::GitHubClient)
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(validation_client)
      allow(validation_client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })

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
      allow(engine).to receive(:validate_token).and_return(true)
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
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
      allow(client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })
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
      allow(engine).to receive(:validate_token).and_return(true)
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
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
      allow(client).to receive(:validate_token_with_reason).and_return({ valid: true, reason: nil })
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

  describe 'token validation before translation' do
    it 'validates both tokens before attempting translation' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)

        expect(engine).to receive(:validate_token).ordered.and_return(true)
        expect(github_client).to receive(:validate_token_with_reason).ordered.and_return({ valid: true, reason: nil })

        allow(translator).to receive(:translate_strings).and_return({ 'fr' => {} })
        allow(translator).to receive(:apply_translations).and_return([])

        translator.run
      end
    end

    it 'raises error and does not translate when LLM token is invalid' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        allow(engine).to receive(:validate_token).and_return(false)
        expect(engine).not_to receive(:get_translations)

        expect do
          translator.run
        end.to raise_error(/LLM API token validation failed/)
      end
    end

    it 'raises error and does not translate when GitHub token is invalid' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        allow(engine).to receive(:validate_token).and_return(true)

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:validate_token_with_reason).and_return({
                                                                                  valid: false,
                                                                                  reason: :no_push_permission
                                                                                })

        expect(engine).not_to receive(:get_translations)

        expect do
          translator.run
        end.to raise_error(/does not have push permission/)
      end
    end

    it 'raises error when GitHub token is expired' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        allow(engine).to receive(:validate_token).and_return(true)

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:validate_token_with_reason).and_return({ valid: false, reason: :expired })

        expect do
          translator.run
        end.to raise_error(/expired or invalid/)
      end
    end

    it 'raises error when GitHub token is missing' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        allow(engine).to receive(:validate_token).and_return(true)

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:validate_token_with_reason).and_return({ valid: false, reason: :missing })

        expect do
          translator.run
        end.to raise_error(/missing or empty/)
      end
    end

    it 'raises error when GitHub token lacks PR permission for pull_request delivery' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'],
                                      delivery_method: 'pull_request')

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        allow(engine).to receive(:validate_token).and_return(true)

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:validate_token_with_reason).and_return({
                                                                                  valid: false,
                                                                                  reason: :no_pull_request_permission
                                                                                })

        expect do
          translator.run
        end.to raise_error(/permission to create pull requests/)
      end
    end

    it 'validates tokens are checked before translate_strings is called' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        diff = instance_double(Prism::DiffExaminer, unchanged?: false, changed_strings: Prism::DiffExaminer::Result.new(
          changed_strings: { 'greeting' => 'Hello' },
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: {}
        ))
        allow(Prism::DiffExaminer).to receive(:new).and_return(diff)

        engine = instance_double(Prism::Engines::ChatGPT)
        allow(translator).to receive(:build_engine).and_return(engine)
        allow(translator).to receive(:build_translation_requests).and_return([
                                                                               { 'greeting' => { value: 'Hello',
                                                                                                 locales: ['fr'] } }, []
                                                                             ])

        call_order = []

        allow(engine).to receive(:validate_token) do
          call_order << :llm_validate
          true
        end

        github_client = instance_double(Prism::GitHubClient)
        allow(Prism::GitHubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:validate_token_with_reason) do
          call_order << :github_validate
          { valid: true, reason: nil }
        end

        allow(engine).to receive(:get_translations) do
          call_order << :translate
          { 'translations' => { 'fr' => 'Bonjour' } }
        end

        allow(translator).to receive(:apply_translations).and_return([])

        translator.run

        expect(call_order.index(:llm_validate)).to be < call_order.index(:translate)
        expect(call_order.index(:github_validate)).to be < call_order.index(:translate)
      end
    end
  end

  describe 'reason to message mapping for GitHub token validation' do
    pr_permission_message = 'GitHub token does not have permission to create pull requests for repository org/repo.'
    messages = {
      missing: 'GitHub token is missing or empty.',
      expired: 'GitHub token is expired or invalid.',
      no_access: 'GitHub token does not have access to repository org/repo.',
      no_push_permission: 'GitHub token does not have push permission for repository org/repo.',
      no_pull_request_permission: pr_permission_message
    }

    def stub_token_validation(result, delivery_method: 'pull_request')
      client = instance_double(Prism::GitHubClient)
      allow(Prism::GitHubClient).to receive(:new).with(token: 'gh', repo_slug: 'org/repo').and_return(client)
      expect(client).to receive(:validate_token_with_reason).with(delivery_method: delivery_method).and_return(result)
      client
    end

    messages.each do |reason, message|
      it "stops the run with a message naming the #{reason} problem" do
        translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
        stub_token_validation({ valid: false, reason: reason })

        expect { translator.send(:validate_tokens, engine_validating(true)) }.to raise_error(RuntimeError, message)
      end
    end

    it 'passes the normalized delivery method when validating for a push run' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    delivery_method: ' Push ')
      stub_token_validation({ valid: false, reason: :no_push_permission }, delivery_method: 'push')

      expect { translator.send(:validate_tokens, engine_validating(true)) }
        .to raise_error(RuntimeError, messages[:no_push_permission])
    end

    it 'falls back to the client message for a reason it does not know' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      stub_token_validation({ valid: false, reason: :error, message: 'end of file reached' })

      expect { translator.send(:validate_tokens, engine_validating(true)) }
        .to raise_error(RuntimeError, 'GitHub token validation failed: end of file reached')
    end

    it 'says unknown error when an unrecognized reason carries no message' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      stub_token_validation({ valid: false, reason: nil })

      expect { translator.send(:validate_tokens, engine_validating(true)) }
        .to raise_error(RuntimeError, 'GitHub token validation failed: unknown error')
    end

    it 'returns silently when both tokens validate' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      stub_token_validation({ valid: true, reason: nil })

      expect(translator.send(:validate_tokens, engine_validating(true))).to be_nil
    end

    it 'checks the LLM token first and never reaches GitHub when it fails' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      expect(Prism::GitHubClient).not_to receive(:new)
      message = 'LLM API token validation failed. Please check your API token is valid and has access to completions.'

      expect { translator.send(:validate_tokens, engine_validating(false)) }
        .to raise_error(RuntimeError, message)
    end
  end

  describe 'building the engine' do
    it 'builds a ChatGPT engine with the configured token, model and retries' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    api_token: 'sk-engine', retries: 2)
      engine = instance_double(Prism::Engines::ChatGPT)
      expect(Prism::Engines::ChatGPT).to receive(:new)
        .with(api_token: 'sk-engine', model: 'gpt-5-mini', retries: 2).and_return(engine)

      expect(translator.send(:build_engine)).to eq(engine)
    end

    it 'refuses an engine it does not implement before any translation work' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'], engine: 'Claude')

      expect { translator.send(:build_engine) }.to raise_error(ArgumentError, 'Unknown engine: Claude')
    end
  end

  describe 'the delivery method' do
    it 'normalizes the configured method' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    delivery_method: ' Pull_Request ')

      expect(translator.send(:delivery_method)).to eq('pull_request')
    end

    it 'refuses a method it does not implement' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    delivery_method: 'email')

      expect { translator.send(:delivery_method) }
        .to raise_error(ArgumentError, 'Unknown delivery method: email')
    end

    it 'refuses an unknown method when a run validates tokens' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    delivery_method: 'email')
      stub_github_client

      expect { translator.send(:validate_tokens, engine_validating(true)) }
        .to raise_error(ArgumentError, 'Unknown delivery method: email')
    end
  end

  describe 'translation failures from the engine' do
    def engine_returning(result)
      engine = instance_double(Prism::Engines::ChatGPT)
      allow(engine).to receive(:get_translations).and_return(result)
      engine
    end

    it 'collects a translation for every requested locale' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: %w[fr de])
      engine = engine_returning({ 'translations' => { 'fr' => 'Bonjour', 'de' => 'Hallo' } })
      requests = { 'greeting' => { value: 'Hello', locales: %w[fr de] } }

      translations = translator.send(:translate_strings, engine, requests)

      expect(translations).to eq({ 'fr' => { 'greeting' => 'Bonjour' }, 'de' => { 'greeting' => 'Hallo' } })
    end

    it 'raises and logs the per-locale reason when a locale comes back empty' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: %w[fr de])
      engine = engine_returning({ 'translations' => { 'fr' => 'Bonjour' },
                                  'errors' => { 'de' => 'HTTP 429: rate limited' } })
      requests = { 'greeting' => { value: 'Hello', locales: %w[fr de] } }

      expect { translator.send(:translate_strings, engine, requests) }.to raise_error('Translation failures detected')
      expect(logged_output).to include('"greeting"')
      expect(logged_output).to include('"de": "HTTP 429: rate limited"')
    end

    it 'logs the request level reason when no locale reason is given' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      engine = engine_returning({ 'translations' => {}, 'errors' => { '_request' => 'No tool call in response' } })
      requests = { 'greeting' => { value: 'Hello', locales: ['fr'] } }

      expect { translator.send(:translate_strings, engine, requests) }.to raise_error('Translation failures detected')
      expect(logged_output).to include('"fr": "No tool call in response"')
    end

    it 'logs a default reason when the engine reports no error at all' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      requests = { 'greeting' => { value: 'Hello', locales: ['fr'] } }

      expect do
        translator.send(:translate_strings, engine_returning({}), requests)
      end.to raise_error('Translation failures detected')
      expect(logged_output).to include('"fr": "no translation returned"')
    end

    it 'treats a whitespace translation as a failure' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: %w[fr de])
      engine = engine_returning({ 'translations' => { 'fr' => "   \n", 'de' => 'Hallo' } })
      requests = { 'greeting' => { value: 'Hello', locales: %w[fr de] } }

      expect { translator.send(:translate_strings, engine, requests) }.to raise_error('Translation failures detected')
      expect(logged_output).to include('"fr": "no translation returned"')
      expect(logged_output).not_to include('"de"')
    end

    it 'aggregates failures across keys and locales before raising once' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: %w[fr de])
      engine = instance_double(Prism::Engines::ChatGPT)
      allow(engine).to receive(:get_translations).with('Hello', %w[fr de])
                                                 .and_return({ 'translations' => { 'fr' => 'Bonjour' },
                                                               'errors' => { 'de' => 'refused' } })
      allow(engine).to receive(:get_translations).with('Goodbye', ['fr'])
                                                 .and_return({ 'translations' => {},
                                                               'errors' => { 'fr' => 'timeout' } })
      requests = {
        'greeting' => { value: 'Hello', locales: %w[fr de] },
        'farewell' => { value: 'Goodbye', locales: ['fr'] }
      }

      expect { translator.send(:translate_strings, engine, requests) }.to raise_error('Translation failures detected')
      expect(logged_output).to include('"greeting"')
      expect(logged_output).to include('"farewell"')
      expect(logged_output).to include('"de": "refused"')
      expect(logged_output).to include('"fr": "timeout"')
    end

    it 'skips a request whose source value is not a string' do
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'])
      engine = instance_double(Prism::Engines::ChatGPT)
      expect(engine).not_to receive(:get_translations)
      requests = { 'group' => { value: { 'one' => 'One' }, locales: ['fr'] } }

      translations = translator.send(:translate_strings, engine, requests)

      expect(translations).to be_empty
    end
  end

  describe 'pushing through a tokenized remote' do
    def repo_capturing_remote_url(url, lookup_succeeds: true)
      commands = []
      repo = instance_double(Prism::GitRepo)
      allow(repo).to receive(:capture) do |command|
        commands << command
        if command != 'git remote get-url origin'
          ['', stub_status(true)]
        elsif lookup_succeeds
          [url, stub_status(true)]
        else
          ["error: No such remote 'origin'", stub_status(false)]
        end
      end
      [repo, commands]
    end

    it 'adds a token remote for an https origin, yields it, and removes it afterwards' do
      repo, commands = repo_capturing_remote_url("https://github.com/org/repo.git\n")
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'],
                                    github_token: 'ghp_token', repo: repo)
      yielded = []

      translator.send(:with_token_remote) { |remote| yielded << remote }

      expect(yielded).to eq(['token'])
      expect(commands).to include('git remote add token https://x-access-token:ghp_token@github.com/org/repo.git')
      expect(commands).to end_with('git remote remove token')
    end

    it 'yields origin untouched when the origin is not https' do
      repo, commands = repo_capturing_remote_url("git@github.com:org/repo.git\n")
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'], repo: repo)
      yielded = []

      translator.send(:with_token_remote) { |remote| yielded << remote }

      expect(yielded).to eq(['origin'])
      expect(commands.grep(/remote add/)).to be_empty
      expect(commands).to end_with('git remote remove token')
    end

    it 'yields origin when the origin url cannot be read' do
      repo, commands = repo_capturing_remote_url(nil, lookup_succeeds: false)
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'], repo: repo)
      yielded = []

      translator.send(:with_token_remote) { |remote| yielded << remote }

      expect(yielded).to eq(['origin'])
      expect(commands.grep(/remote add/)).to be_empty
      expect(commands).to end_with('git remote remove token')
    end

    it 'removes the token remote even when the push fails' do
      repo, commands = repo_capturing_remote_url("https://github.com/org/repo.git\n")
      translator = build_translator(source_file: 'locales/en.json', target_languages: ['fr'], repo: repo)

      expect do
        translator.send(:with_token_remote) { raise 'remote rejected the push' }
      end.to raise_error('remote rejected the push')
      expect(commands).to end_with('git remote remove token')
    end
  end

  describe 'guards that stop a bad translation delivery' do
    it 'refuses to push from a detached HEAD' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:current_branch).and_return('HEAD')
        stub_github_client

        expect { translator.run }.to raise_error(/Cannot push translation commit because current branch is detached/)
        expect(repo).not_to have_received(:set_identity)
        expect(repo).not_to have_received(:commit)
      end
    end

    [nil, ''].each do |branch|
      it "refuses to push when the current branch reads as #{branch.inspect}" do
        Dir.mktmpdir do |dir|
          write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
          translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                        delivery_method: 'push')
          allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
          repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
          allow(repo).to receive(:current_branch).and_return(branch)
          stub_github_client

          expect { translator.run }.to raise_error(/current branch is detached/)
          expect(repo).not_to have_received(:add)
        end
      end
    end

    it 'refuses to translate when the staged diff cannot be read' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:staged_diff).and_return(nil)
        stub_github_client

        expect { translator.run }.to raise_error('Failed to get staged diff')
        expect(repo).not_to have_received(:commit)
      end
    end

    it 'refuses to translate when the source commit diff cannot be read for an LLM commit message' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push', llm_commit_messages: true)
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:show_commit).with('sha').and_return(nil)
        stub_github_client

        expect { translator.run }.to raise_error('Failed to get source commit diff')
        expect(repo).not_to have_received(:commit)
      end
    end

    it 'raises when git refuses to create the commit' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:commit).and_return(['nothing added to commit', stub_status(false)])
        stub_github_client

        expect { translator.run }.to raise_error('Failed to create commit: nothing added to commit')
        expect(repo).not_to have_received(:push)
      end
    end

    it 'raises when the commit does not advance HEAD' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:head_sha).and_return('same-sha', 'same-sha')
        stub_github_client

        expect { translator.run }.to raise_error(/Commit did not advance HEAD\. Output: commit output/)
        expect(repo).not_to have_received(:push)
      end
    end

    it 'raises when HEAD cannot be read after the commit' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:head_sha).and_return('before-sha', nil)
        stub_github_client

        expect { translator.run }.to raise_error(/Commit did not advance HEAD/)
        expect(repo).not_to have_received(:push)
      end
    end

    it 'raises when the commit is missing an expected locale file' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:changed_files).and_return([])
        stub_github_client

        expect { translator.run }.to raise_error(
          %r{Commit after-sha missing expected file changes: locales/fr\.json\. Changed files: }
        )
        expect(repo).not_to have_received(:push)
      end
    end

    it 'raises when the commit carries a file nobody asked for' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:changed_files).and_return(['locales/fr.json', 'locales/es.json'])
        stub_github_client

        expect { translator.run }.to raise_error(
          %r{Commit after-sha included unexpected files: locales/es\.json\. Expected: locales/fr\.json}
        )
        expect(repo).not_to have_received(:push)
      end
    end

    it 'raises when the push fails' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'],
                                      delivery_method: 'push')
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        repo = stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        allow(repo).to receive(:push).and_return(['remote: permission denied', stub_status(false)])
        stub_github_client

        expect { translator.run }.to raise_error('Failed to push branch main to origin: remote: permission denied')
      end
    end

    it 'raises when the remote branch does not point at the translation commit' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'])
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        client = stub_github_client
        allow(client).to receive(:branch_head_sha).and_return('someone-elses-sha')

        expect { translator.run }.to raise_error(
          /does not point to commit after-sha\. Found: someone-elses-sha/
        )
        expect(client).not_to have_received(:create_pull_request)
      end
    end

    it 'raises when the remote branch is missing entirely' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'])
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        client = stub_github_client
        allow(client).to receive(:branch_head_sha).and_return(nil)

        expect { translator.run }.to raise_error(/does not point to commit after-sha\. Found: none/)
        expect(client).not_to have_received(:create_pull_request)
      end
    end

    [nil, { 'html_url' => 'https://github.com/org/repo/pulls/12' }].each do |response|
      it "raises when pull request creation answers #{response.inspect}" do
        Dir.mktmpdir do |dir|
          write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
          translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'])
          allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
          stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
          client = stub_github_client
          allow(client).to receive(:create_pull_request).and_return(response)

          expect { translator.run }.to raise_error('Pull request creation did not return a PR number.')
          expect(client).not_to have_received(:pull_request_for_branch)
        end
      end
    end

    it 'raises when no pull request is listed for the branch after creation' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'])
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        client = stub_github_client
        allow(client).to receive(:pull_request_for_branch).and_return(nil)

        expect { translator.run }
          .to raise_error(%r{Pull request for branch i18n/auto-translate-\d{14} not found after creation\.})
        expect(client).to have_received(:create_pull_request)
      end
    end

    it 'raises when a different pull request is listed for the branch after creation' do
      Dir.mktmpdir do |dir|
        write_json(File.join(dir, 'locales/en.json'), { 'greeting' => 'Hello' })
        translator = build_translator(source_file: File.join(dir, 'locales/en.json'), target_languages: ['fr'])
        allow(Prism::DiffExaminer).to receive(:new).and_return(changed_greeting_diff)
        stub_translations_committed(translator, File.join(dir, 'locales/fr.json'))
        client = stub_github_client
        allow(client).to receive(:pull_request_for_branch).and_return({ 'number' => 7 })

        expect { translator.run }
          .to raise_error(%r{Pull request for branch i18n/auto-translate-\d{14} not found after creation\.})
      end
    end
  end

  describe 'request building details' do
    it 'skips backfilled keys whose source value is not a string' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'greeting' => 'Hello' })

        translator = build_translator(source_file: source_path, target_languages: ['fr'])
        result = Prism::DiffExaminer::Result.new(
          changed_strings: {},
          source_locale_root: nil,
          added_strings: {},
          modified_strings: {},
          source_strings: { 'greeting' => 'Hello', 'group' => { 'one' => 'One' } }
        )

        requests, = translator.send(:build_translation_requests, result)

        expect(requests.keys).to contain_exactly('greeting')
      end
    end

    it 'honours the exceptions file for backfilled and changed keys' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.json')
        write_json(source_path, { 'private' => 'Secret', 'other' => 'Other' })
        write_json(File.join(dir, '.prism/exceptions.json'), { 'private' => ['fr'], 'banner' => %w[fr de] })
        write_json(File.join(dir, 'locales/de.json'), { 'other' => 'Anderes' })

        translator = build_translator(source_file: source_path, target_languages: %w[fr de])
        result = Prism::DiffExaminer::Result.new(
          changed_strings: { 'banner' => 'Banner' },
          source_locale_root: nil,
          added_strings: { 'banner' => 'Banner' },
          modified_strings: {},
          source_strings: { 'private' => 'Secret', 'other' => 'Other', 'banner' => 'Banner' }
        )

        requests, = translator.send(:build_translation_requests, result)

        expect(requests.keys).to contain_exactly('private', 'other')
        expect(requests['private'][:locales]).to eq(['de'])
        expect(requests['other'][:locales]).to eq(['fr'])
      end
    end

    it 'reads YAML target files while collecting stale keys' do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, 'locales/en.yml')
        fr_path = File.join(dir, 'locales/fr.yml')
        FileUtils.mkdir_p(File.dirname(source_path))
        File.write(source_path, YAML.dump({ 'en' => { 'greeting' => 'Hello' } }))
        File.write(fr_path, YAML.dump({ 'fr' => { 'greeting' => 'Bonjour', 'gone' => 'Parti' } }))

        translator = build_translator(source_file: source_path, target_languages: ['fr'])

        expect(translator.send(:stale_keys_by_locale, { 'greeting' => 'Hello' })).to eq({ 'fr' => ['gone'] })
      end
    end
  end
end
