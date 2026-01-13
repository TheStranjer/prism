# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Prism::ExclusionsHandler do
  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
  end

  describe '#excluded?' do
    it 'returns true for keys excluded for the specified locale' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {
                     'abc.def' => %w[pl de],
                     'xyz.123' => %w[es fr ru]
                   })

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be true
        expect(handler.excluded?('abc.def', 'de')).to be true
        expect(handler.excluded?('xyz.123', 'es')).to be true
        expect(handler.excluded?('xyz.123', 'fr')).to be true
        expect(handler.excluded?('xyz.123', 'ru')).to be true
      end
    end

    it 'returns false for keys not excluded for the specified locale' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {
                     'abc.def' => %w[pl de],
                     'xyz.123' => %w[es fr ru]
                   })

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'es')).to be false
        expect(handler.excluded?('abc.def', 'fr')).to be false
        expect(handler.excluded?('xyz.123', 'pl')).to be false
        expect(handler.excluded?('xyz.123', 'de')).to be false
      end
    end

    it 'returns false for keys not in the exceptions list' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, { 'abc.def' => %w[pl de] })

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('other.key', 'pl')).to be false
        expect(handler.excluded?('other.key', 'de')).to be false
      end
    end

    it 'returns false when exceptions file does not exist' do
      handler = described_class.new(exceptions_path: '/nonexistent/path.json')

      expect(handler.excluded?('abc.def', 'pl')).to be false
    end

    it 'returns false when exceptions file is empty' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        File.write(exceptions_path, '')

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be false
      end
    end

    it 'handles invalid JSON gracefully' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        File.write(exceptions_path, '{ invalid json }')

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be false
      end
    end

    it 'handles non-object JSON gracefully' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, %w[abc.def xyz.123])

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be false
      end
    end

    it 'ignores non-string locales in the array' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        File.write(exceptions_path, '{"abc.def": ["pl", 123, null, {"key": "value"}, "de"]}')

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be true
        expect(handler.excluded?('abc.def', 'de')).to be true
        expect(handler.excluded?('abc.def', '123')).to be false
      end
    end

    it 'ignores entries with non-array values' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        File.write(exceptions_path, '{"abc.def": "pl", "xyz.123": ["es"]}')

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded?('abc.def', 'pl')).to be false
        expect(handler.excluded?('xyz.123', 'es')).to be true
      end
    end
  end

  describe '#excluded_locales' do
    it 'returns the list of excluded locales for a key' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {
                     'abc.def' => %w[pl de],
                     'xyz.123' => %w[es fr ru]
                   })

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded_locales('abc.def')).to contain_exactly('pl', 'de')
        expect(handler.excluded_locales('xyz.123')).to contain_exactly('es', 'fr', 'ru')
      end
    end

    it 'returns an empty array for keys not in the exceptions list' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, { 'abc.def' => %w[pl de] })

        handler = described_class.new(exceptions_path: exceptions_path)

        expect(handler.excluded_locales('other.key')).to eq([])
      end
    end
  end

  describe '#filter' do
    it 'removes keys excluded for the specified locale from a hash' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {
                     'abc.def' => %w[pl de],
                     'xyz.123' => %w[es fr]
                   })

        handler = described_class.new(exceptions_path: exceptions_path)
        input = {
          'abc.def' => 'value1',
          'other.key' => 'value2',
          'xyz.123' => 'value3',
          'keep.this' => 'value4'
        }

        result = handler.filter(input, 'pl')

        expect(result).to eq({
                               'other.key' => 'value2',
                               'xyz.123' => 'value3',
                               'keep.this' => 'value4'
                             })
      end
    end

    it 'keeps keys that are excluded for other locales' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, { 'abc.def' => %w[pl de] })

        handler = described_class.new(exceptions_path: exceptions_path)
        input = { 'abc.def' => 'value1', 'other.key' => 'value2' }

        result = handler.filter(input, 'es')

        expect(result).to eq(input)
      end
    end

    it 'returns the original hash when no keys are excluded for the locale' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {})

        handler = described_class.new(exceptions_path: exceptions_path)
        input = { 'a' => '1', 'b' => '2' }

        result = handler.filter(input, 'pl')

        expect(result).to eq(input)
      end
    end
  end

  describe '#exclusions' do
    it 'returns a copy of the exclusions' do
      Dir.mktmpdir do |dir|
        exceptions_path = File.join(dir, 'exceptions.json')
        write_json(exceptions_path, {
                     'abc.def' => %w[pl de],
                     'xyz.123' => %w[es]
                   })

        handler = described_class.new(exceptions_path: exceptions_path)

        exclusions = handler.exclusions
        expect(exclusions['abc.def']).to contain_exactly('pl', 'de')
        expect(exclusions['xyz.123']).to contain_exactly('es')

        exclusions['abc.def'].add('fr')
        expect(handler.exclusions['abc.def']).to contain_exactly('pl', 'de')
      end
    end
  end

  describe 'finding exceptions file from source_file' do
    it 'finds exceptions file in parent directory of source file' do
      Dir.mktmpdir do |dir|
        prism_dir = File.join(dir, '.prism')
        FileUtils.mkdir_p(prism_dir)
        exceptions_path = File.join(prism_dir, 'exceptions.json')
        write_json(exceptions_path, { 'excluded.key' => %w[pl de] })

        locales_dir = File.join(dir, 'src', 'locales')
        FileUtils.mkdir_p(locales_dir)
        source_file = File.join(locales_dir, 'en.json')
        File.write(source_file, '{}')

        handler = described_class.new(source_file: source_file)

        expect(handler.excluded?('excluded.key', 'pl')).to be true
        expect(handler.excluded?('excluded.key', 'es')).to be false
        expect(handler.excluded?('other.key', 'pl')).to be false
      end
    end

    it 'finds exceptions file in same directory as source file' do
      Dir.mktmpdir do |dir|
        locales_dir = File.join(dir, 'locales')
        prism_dir = File.join(locales_dir, '.prism')
        FileUtils.mkdir_p(prism_dir)
        exceptions_path = File.join(prism_dir, 'exceptions.json')
        write_json(exceptions_path, { 'local.exception' => %w[fr] })

        source_file = File.join(locales_dir, 'en.json')
        File.write(source_file, '{}')

        handler = described_class.new(source_file: source_file)

        expect(handler.excluded?('local.exception', 'fr')).to be true
      end
    end

    it 'returns empty exclusions when no exceptions file is found' do
      Dir.mktmpdir do |dir|
        locales_dir = File.join(dir, 'locales')
        FileUtils.mkdir_p(locales_dir)
        source_file = File.join(locales_dir, 'en.json')
        File.write(source_file, '{}')

        handler = described_class.new(source_file: source_file)

        expect(handler.excluded?('any.key', 'pl')).to be false
        expect(handler.exclusions).to be_empty
      end
    end

    it 'prefers explicit exceptions_path over source_file lookup' do
      Dir.mktmpdir do |dir|
        explicit_path = File.join(dir, 'explicit', 'exceptions.json')
        FileUtils.mkdir_p(File.dirname(explicit_path))
        write_json(explicit_path, { 'explicit.key' => %w[pl] })

        prism_dir = File.join(dir, '.prism')
        FileUtils.mkdir_p(prism_dir)
        write_json(File.join(prism_dir, 'exceptions.json'), { 'implicit.key' => %w[pl] })

        source_file = File.join(dir, 'locales', 'en.json')
        FileUtils.mkdir_p(File.dirname(source_file))
        File.write(source_file, '{}')

        handler = described_class.new(exceptions_path: explicit_path, source_file: source_file)

        expect(handler.excluded?('explicit.key', 'pl')).to be true
        expect(handler.excluded?('implicit.key', 'pl')).to be false
      end
    end
  end
end
