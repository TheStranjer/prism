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

    it 'returns nil when the backing data is not a hash' do
      locale = described_class.new(%w[not a hash])

      expect(locale.remove_value('anything')).to be_nil
    end
  end
end
