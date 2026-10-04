# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Prism::LocaleFile do
  it 'infers root locale and flattens strings' do
    data = { 'en' => { 'greeting' => 'Hello', 'home' => { 'title' => 'Home' } } }
    locale = described_class.new(data, locale_hint: 'en')

    expect(locale.root_key).to eq('en')
    expect(locale.flattened_strings).to eq({ 'greeting' => 'Hello', 'home.title' => 'Home' })
  end

  it 'sets nested values' do
    locale = described_class.new({ 'en' => {} }, locale_hint: 'en')
    locale.set_value('home.title', 'Homepage')

    expect(locale.to_serialized(:json)).to include('Homepage')
  end

  describe '#set_value' do
    it 'records no collision when the write only creates missing namespaces' do
      locale = described_class.new({ 'home' => { 'title' => 'Home' } })

      locale.set_value('home.subtitle', 'Subtitle')

      expect(locale.data).to eq({ 'home' => { 'title' => 'Home', 'subtitle' => 'Subtitle' } })
      expect(locale.collisions).to eq([])
    end

    it 'records no collision when the write overwrites a leaf string' do
      locale = described_class.new({ 'greeting' => 'Hello' })

      locale.set_value('greeting', 'Hi')

      expect(locale.collisions).to eq([])
    end

    it 'records a collision when the write rebuilds a string into a namespace' do
      locale = described_class.new({ 'a' => 'Ancien' })

      locale.set_value('a.b', 'Pomme')

      expect(locale.data).to eq({ 'a' => { 'b' => 'Pomme' } })
      collision = { 'operation' => 'write', 'path' => 'a.b', 'collision_path' => 'a', 'value' => 'Ancien' }
      expect(locale.collisions).to eq([collision])
    end

    it 'records a collision when the write rebuilds a null node into a namespace' do
      locale = described_class.new({ 'a' => nil })

      locale.set_value('a.b', 'Pomme')

      collision = { 'operation' => 'write', 'path' => 'a.b', 'collision_path' => 'a', 'value' => nil }
      expect(locale.collisions).to eq([collision])
    end

    it 'records one collision per rebuilt node along a deep write' do
      locale = described_class.new({ 'a' => 'Ancien' })

      locale.set_value('a.b.c', 'Pomme')

      expect(locale.collisions.length).to eq(1)
      expect(locale.collisions.first['collision_path']).to eq('a')
    end
  end

  describe '#detect_root_key' do
    it 'ignores a lone top-level key that matches neither the locale hint nor the source root' do
      locale = described_class.new({ 'a' => { 'b' => 'Ameise' } }, locale_hint: 'fr')

      expect(locale.root_key).to be_nil
      expect(locale.flattened_strings).to eq({ 'a.b' => 'Ameise' })
    end

    it 'accepts a lone top-level key matching the locale hint' do
      locale = described_class.new({ 'fr' => { 'b' => 'Ameise' } }, locale_hint: 'fr')

      expect(locale.root_key).to eq('fr')
      expect(locale.flattened_strings).to eq({ 'b' => 'Ameise' })
    end

    it 'accepts a lone top-level key matching the source file root' do
      locale = described_class.new({ 'en' => { 'greeting' => 'Bonjour' } }, locale_hint: 'fr', source_root_key: 'en')

      expect(locale.root_key).to eq('en')
      expect(locale.flattened_strings).to eq({ 'greeting' => 'Bonjour' })
    end

    it 'still rejects the source root key when the value is not a hash' do
      locale = described_class.new({ 'en' => 'Bonjour' }, locale_hint: 'fr', source_root_key: 'en')

      expect(locale.root_key).to be_nil
      expect(locale.flattened_strings).to eq({ 'en' => 'Bonjour' })
    end
  end

  describe '#remove_value' do
    it 'removes a top-level key and returns the removed value' do
      locale = described_class.new({ 'greeting' => 'Hello', 'stale' => 'Old' })

      expect(locale.remove_value('stale')).to eq('Old')
      expect(locale.flattened_strings).to eq({ 'greeting' => 'Hello' })
    end

    it 'removes a nested key under the root locale and keeps non-empty parents' do
      locale = described_class.new(
        { 'en' => { 'home' => { 'title' => 'Home', 'gone' => 'Old' }, 'keep' => 'Kept' } },
        locale_hint: 'en'
      )

      expect(locale.remove_value('home.gone')).to eq('Old')
      expect(locale.data).to eq({ 'en' => { 'home' => { 'title' => 'Home' }, 'keep' => 'Kept' } })
    end

    it 'prunes emptied parents up to the root key' do
      locale = described_class.new({ 'fr' => { 'a' => { 'b' => { 'c' => 'Old' } } } }, locale_hint: 'fr')

      expect(locale.remove_value('a.b.c')).to eq('Old')
      expect(locale.data).to eq({ 'fr' => {} })
    end

    it 'returns nil and changes nothing when the leaf key is missing' do
      locale = described_class.new({ 'de' => { 'home' => { 'title' => 'Startseite' } } }, locale_hint: 'de')

      expect(locale.remove_value('home.missing')).to be_nil
      expect(locale.data).to eq({ 'de' => { 'home' => { 'title' => 'Startseite' } } })
    end

    it 'returns nil when an intermediate key is not a hash' do
      locale = described_class.new({ 'greeting' => 'Hello' })

      expect(locale.remove_value('greeting.deeper')).to be_nil
      expect(locale.flattened_strings).to eq({ 'greeting' => 'Hello' })
    end

    it 'records a collision when an intermediate key is not a hash' do
      locale = described_class.new({ 'greeting' => 'Hello' })

      expect(locale.remove_value('greeting.deeper')).to be_nil

      collision = {
        'operation' => 'removal',
        'path' => 'greeting.deeper',
        'collision_path' => 'greeting',
        'value' => 'Hello'
      }
      expect(locale.collisions).to eq([collision])
    end

    it 'records no collision when an intermediate key is simply missing' do
      locale = described_class.new({ 'home' => { 'title' => 'Home' } })

      expect(locale.remove_value('absent.deeper')).to be_nil
      expect(locale.remove_value('home.missing')).to be_nil
      expect(locale.collisions).to eq([])
    end

    it 'returns nil when the backing data is not a hash' do
      locale = described_class.new(%w[not a hash])

      expect(locale.remove_value('anything')).to be_nil
    end
  end
end
