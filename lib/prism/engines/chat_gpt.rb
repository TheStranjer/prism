# frozen_string_literal: true

require 'faraday'
require 'json'

module Prism
  module Engines
    class ChatGPT < Base
      OPENAI_URL = 'https://api.openai.com/v1/chat/completions'
      MODELS_URL = 'https://api.openai.com/v1/models'

      def initialize(api_token:, model:, retries: 5, http_client: nil)
        super(api_token: api_token, model: model)
        @retries = validate_retries(retries)
        @http_client = http_client || Faraday.new
      end

      def get_translations(text, target_languages)
        messages = base_messages(text, target_languages)
        last_error = nil

        (0..@retries).each do
          payload = build_payload(messages, target_languages)
          response = @http_client.post(OPENAI_URL, payload.to_json, headers)
          return error_payload("HTTP #{response.status}: #{response.body}") unless response.success?

          body = JSON.parse(response.body)
          message = body.dig('choices', 0, 'message') || {}
          arguments = tool_arguments_from(message)
          unless arguments
            last_error = 'No tool call or JSON content in response'
            messages = retry_messages(messages, last_error)
            next
          end

          parsed = JSON.parse(arguments)
          unless parsed.is_a?(Hash)
            last_error = 'Tool call arguments are not a JSON object'
            messages = retry_messages(messages, last_error)
            next
          end

          missing_locales = missing_locales(parsed['translations'], target_languages)
          return parsed if missing_locales.empty?

          last_error = "Missing translations for locales: #{missing_locales.join(', ')}"
          messages = retry_messages(messages, last_error)
        end

        error_payload(last_error || 'No tool call or JSON content in response')
      rescue JSON::ParserError => e
        error_payload("Invalid JSON in tool call arguments: #{e.message}")
      rescue StandardError => e
        error_payload("Unexpected error parsing translation response: #{e.message}")
      end

      def generate_commit_content(source_commit_diff:, staged_diff:, delivery_method:)
        tool = commit_tool(delivery_method)
        tool_name = tool[:function][:name]
        messages = [
          { role: 'system', content: commit_system_prompt(delivery_method) },
          { role: 'user',
            content: "Here is the original commit that triggered the translation:\n\n#{source_commit_diff}" },
          { role: 'user', content: "Here are the staged translation changes to be committed:\n\n#{staged_diff}" }
        ]

        payload = {
          model: @model,
          messages: messages,
          tools: [tool],
          tool_choice: { type: 'function', function: { name: tool_name } }
        }

        response = @http_client.post(OPENAI_URL, payload.to_json, headers)
        raise "HTTP #{response.status}: #{response.body}" unless response.success?

        body = JSON.parse(response.body)
        message = body.dig('choices', 0, 'message') || {}
        arguments = tool_arguments_from(message)
        raise 'No tool call in response for commit message generation' unless arguments

        parsed = JSON.parse(arguments)
        validate_commit_content(parsed, delivery_method)
        parsed
      end

      def validate_token
        return false if @api_token.nil? || @api_token.strip.empty?

        response = @http_client.get(MODELS_URL, nil, headers)
        return false unless response.success?

        body = JSON.parse(response.body)
        available_models = body['data']&.map { |m| m['id'] } || []
        available_models.include?(@model)
      rescue StandardError
        false
      end

      private

      def headers
        {
          'Authorization' => "Bearer #{@api_token}",
          'Content-Type' => 'application/json'
        }
      end

      def build_payload(messages, target_languages)
        tool = translation_tool(target_languages)
        {
          model: @model,
          messages: messages,
          tools: [tool],
          tool_choice: { type: 'function', function: { name: tool[:function][:name] } }
        }
      end

      def system_prompt(target_languages)
        'You are a translation engine for i18n strings. ' \
          "Translate the user message into each of: #{target_languages.join(', ')}. " \
          'You must call the translations tool and provide non-empty values for every locale key. ' \
          'Preserve placeholders and formatting exactly (e.g., %<name>s, {{count}}, %s). ' \
          'If a locale cannot be translated, include an error message for that locale in errors.'
      end

      def translation_tool(target_languages)
        locale_properties = target_languages.each_with_object({}) do |locale, hash|
          hash[locale] = {
            type: 'string',
            description: "Translation for locale #{locale}."
          }
        end

        {
          type: 'function',
          function: {
            name: 'translations',
            description: 'Return translations keyed by target locale, and optional per-locale errors.',
            parameters: {
              type: 'object',
              properties: {
                translations: {
                  type: 'object',
                  properties: locale_properties,
                  required: target_languages,
                  additionalProperties: false
                },
                errors: {
                  type: 'object',
                  properties: locale_properties.merge(
                    '_request' => { type: 'string', description: 'Request-level error.' }
                  ),
                  additionalProperties: false
                }
              },
              required: ['translations']
            }
          }
        }
      end

      def tool_arguments_from(message)
        tool_call = message['tool_calls']&.first
        arguments = tool_call&.dig('function', 'arguments')
        return arguments if arguments

        function_call = message['function_call']
        arguments = function_call&.dig('arguments')
        return arguments if arguments

        content = message['content']
        return content if content&.strip&.start_with?('{')

        nil
      end

      def error_payload(message)
        { 'translations' => {}, 'errors' => { '_request' => message } }
      end

      def base_messages(text, target_languages)
        [
          {
            role: 'system',
            content: system_prompt(target_languages)
          },
          {
            role: 'user',
            content: text
          }
        ]
      end

      def retry_messages(messages, reason)
        messages + [
          {
            role: 'user',
            content: "Retry required: #{reason}. Return a tool call with translations for every locale."
          }
        ]
      end

      def missing_locales(translations, target_languages)
        return target_languages if !translations.is_a?(Hash) || translations.empty?

        target_languages.reject do |locale|
          value = translations[locale]
          value.is_a?(String) && !value.strip.empty?
        end
      end

      def validate_retries(retries)
        raise ArgumentError, 'retries must be a non-negative integer' unless retries.is_a?(Integer) && retries >= 0

        retries
      end

      def commit_system_prompt(delivery_method)
        base = 'You are a commit message generator for an automated i18n translation script. ' \
               'The script detects changes in a source locale file, translates the changed strings ' \
               "into target languages using an LLM, and commits the updated locale files.\n\n" \
               "You will receive two pieces of context:\n" \
               '1. The original commit (via `git show`) that triggered this translation - ' \
               "this shows what changed in the source locale file\n" \
               '2. The staged translation changes (via `git diff --cached`) - ' \
               "this shows the translations that will be committed\n\n" \
               'Write a concise, descriptive commit message that captures the essence of the translation changes, ' \
               'informed by understanding what was changed in the original source commit.'

        if delivery_method == 'pull_request'
          base + "\n\nAlso write a pull request title and description. " \
                 'The PR title should be short and action-oriented. ' \
                 'The PR description should summarize the changes and provide context for reviewers, ' \
                 'referencing what was changed in the original source commit.'
        else
          base
        end
      end

      def commit_tool(delivery_method)
        if delivery_method == 'pull_request'
          {
            type: 'function',
            function: {
              name: 'pull_request_commit',
              description: 'Return the commit message, PR title, and PR description for the translation changes.',
              parameters: {
                type: 'object',
                properties: {
                  commit_message: {
                    type: 'string',
                    description: 'A concise commit message describing the translation changes.'
                  },
                  pr_title: {
                    type: 'string',
                    description: 'A short, action-oriented pull request title.'
                  },
                  pr_description: {
                    type: 'string',
                    description: 'A description summarizing the changes and providing context for reviewers.'
                  }
                },
                required: %w[commit_message pr_title pr_description]
              }
            }
          }
        else
          {
            type: 'function',
            function: {
              name: 'push_commit',
              description: 'Return the commit message for the translation changes.',
              parameters: {
                type: 'object',
                properties: {
                  commit_message: {
                    type: 'string',
                    description: 'A concise commit message describing the translation changes.'
                  }
                },
                required: ['commit_message']
              }
            }
          }
        end
      end

      def validate_commit_content(parsed, delivery_method)
        raise 'Commit content is not a hash' unless parsed.is_a?(Hash)

        unless parsed['commit_message'].is_a?(String) && !parsed['commit_message'].strip.empty?
          raise 'Missing or empty commit_message'
        end

        return unless delivery_method == 'pull_request'

        raise 'Missing or empty pr_title' unless parsed['pr_title'].is_a?(String) && !parsed['pr_title'].strip.empty?

        return if parsed['pr_description'].is_a?(String) && !parsed['pr_description'].strip.empty?

        raise 'Missing or empty pr_description'
      end
    end
  end
end
