# frozen_string_literal: true

require 'json'
require 'yaml'

module Prism
  class LocaleFile
    attr_reader :root_key, :data, :collisions

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

    def initialize(data, locale_hint: nil, source_root_key: nil)
      @data = data || {}
      @locale_hint = locale_hint
      @root_key = detect_root_key(@data, locale_hint, source_root_key)
      @collisions = []
    end

    def flattened_strings
      root_data = root_key ? @data.fetch(root_key, {}) : @data
      flatten_hash(root_data)
    end

    def set_value(path, value)
      keys = path.split('.')
      root = root_key ? (@data[root_key] ||= {}) : @data
      cursor = root
      keys[0..-2].each_with_index do |key, depth|
        record_collision('write', path, keys, depth, cursor[key]) if shape_collision?(cursor, key)
        cursor[key] = {} unless cursor[key].is_a?(Hash)
        cursor = cursor[key]
      end
      cursor[keys.last] = value
    end

    def remove_value(path)
      keys = path.split('.')
      root = root_key ? @data[root_key] : @data
      return nil unless root.is_a?(Hash)

      cursor = root
      parents = []
      keys[0..-2].each_with_index do |key, depth|
        record_collision('removal', path, keys, depth, cursor[key]) if shape_collision?(cursor, key)
        return nil unless cursor[key].is_a?(Hash)

        parents << [cursor, key]
        cursor = cursor[key]
      end
      return nil unless cursor.key?(keys.last)

      removed = cursor.delete(keys.last)
      parents.reverse_each do |hash, key|
        break unless hash[key].is_a?(Hash) && hash[key].empty?

        hash.delete(key)
      end
      removed
    end

    def to_serialized(format)
      if format == :json
        JSON.pretty_generate(@data)
      else
        YAML.dump(@data)
      end
    end

    private

    def shape_collision?(cursor, key)
      cursor.key?(key) && !cursor[key].is_a?(Hash)
    end

    def record_collision(operation, path, keys, depth, value)
      @collisions << {
        'operation' => operation,
        'path' => path,
        'collision_path' => keys[0..depth].join('.'),
        'value' => value
      }
    end

    def detect_root_key(data, locale_hint, source_root_key)
      return nil unless data.is_a?(Hash)

      return locale_hint if locale_hint && data.key?(locale_hint) && data[locale_hint].is_a?(Hash)

      if source_root_key && data.keys.length == 1 &&
         data.key?(source_root_key) && data[source_root_key].is_a?(Hash)
        return source_root_key
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
