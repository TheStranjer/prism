# frozen_string_literal: true

require 'json'
require 'yaml'

module Prism
  class DiffExaminer
    Result = Struct.new(
      :changed_strings,
      :source_locale_root,
      :added_strings,
      :modified_strings,
      :source_strings,
      keyword_init: true
    )

    def initialize(repo:, commit:, source_file:, source_locale: nil)
      @repo = repo
      @commit = commit
      @source_file = source_file
      @source_locale = source_locale
    end

    def unchanged?
      output, status = @repo.capture("git diff --name-only #{@commit}^ #{@commit} -- #{@source_file}")
      status.success? && output.strip.empty?
    end

    def changed_strings
      old_content = @repo.git_show("#{@commit}^", @source_file)
      new_content = @repo.git_show(@commit, @source_file)

      old_data = parse_content(old_content)
      new_data = parse_content(new_content)

      old_locale_file = LocaleFile.new(old_data, locale_hint: locale_hint)
      new_locale_file = LocaleFile.new(new_data, locale_hint: locale_hint)

      old_flat = old_locale_file.flattened_strings
      new_flat = new_locale_file.flattened_strings

      added = {}
      modified = {}
      new_flat.each do |key, value|
        unless old_flat.key?(key)
          added[key] = value
          next
        end

        next if old_flat[key] == value

        modified[key] = value
      end

      Result.new(
        changed_strings: added.merge(modified),
        source_locale_root: new_locale_file.root_key,
        added_strings: added,
        modified_strings: modified,
        source_strings: new_flat
      )
    end

    private

    def locale_hint
      @source_locale || LocaleFile.locale_from_path(@source_file)
    end

    def parse_content(content)
      return {} if content.nil? || content.strip.empty?

      if @source_file.end_with?('.json')
        JSON.parse(content)
      else
        YAML.safe_load(content, aliases: true) || {}
      end
    end
  end
end
