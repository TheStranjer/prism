# frozen_string_literal: true

require 'json'
require 'yaml'

module Prism
  class LocaleFile
    attr_reader :root_key, :data

    def self.locale_from_path(path)
      base = File.basename(path)
      File.basename(base, File.extname(base))
    end

    def self.target_path_for(source_path, target_locale)
      ext = File.extname(source_path)
      File.basename(source_path, ext)
      dir = File.dirname(source_path)
      File.join(dir, "#{target_locale}#{ext}")
    end

    def initialize(data, locale_hint: nil)
      @data = data || {}
      @locale_hint = locale_hint
      @root_key = detect_root_key(@data, locale_hint)
    end

    def flattened_strings
      root_data = root_key ? @data.fetch(root_key, {}) : @data
      flatten_hash(root_data)
    end

    def set_value(path, value)
      keys = path.split('.')
      root = root_key ? (@data[root_key] ||= {}) : @data
      cursor = root
      keys[0..-2].each do |key|
        cursor[key] = {} unless cursor[key].is_a?(Hash)
        cursor = cursor[key]
      end
      cursor[keys.last] = value
    end

    def to_serialized(format)
      if format == :json
        JSON.pretty_generate(@data)
      else
        YAML.dump(@data)
      end
    end

    private

    def detect_root_key(data, locale_hint)
      return nil unless data.is_a?(Hash)

      return locale_hint if locale_hint && data.key?(locale_hint) && data[locale_hint].is_a?(Hash)

      if data.keys.length == 1
        only_key = data.keys.first
        return only_key if data[only_key].is_a?(Hash)
      end

      nil
    end

    def flatten_hash(hash, prefix = nil, result = {})
      hash.each do |key, value|
        path = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          flatten_hash(value, path, result)
        elsif value.is_a?(String)
          result[path] = value
        end
      end

      result
    end
  end
end
