# frozen_string_literal: true

require "faraday"
require "json"

module Prism
  module Engines
    class ChatGPT < Base
      OPENAI_URL = "https://api.openai.com/v1/chat/completions"

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
          message = body.dig("choices", 0, "message") || {}
          arguments = tool_arguments_from(message)
          unless arguments
            last_error = "No tool call or JSON content in response"
            messages = retry_messages(messages, last_error)
            next
          end

          parsed = JSON.parse(arguments)
          unless parsed.is_a?(Hash)
            last_error = "Tool call arguments are not a JSON object"
            messages = retry_messages(messages, last_error)
            next
          end

          missing_locales = missing_locales(parsed["translations"], target_languages)
          if missing_locales.empty?
            return parsed
          end

          last_error = "Missing translations for locales: #{missing_locales.join(", ")}"
          messages = retry_messages(messages, last_error)
        end

        error_payload(last_error || "No tool call or JSON content in response")
      rescue JSON::ParserError => e
        error_payload("Invalid JSON in tool call arguments: #{e.message}")
      rescue StandardError => e
        error_payload("Unexpected error parsing translation response: #{e.message}")
      end

      private

      def headers
        {
          "Authorization" => "Bearer #{@api_token}",
          "Content-Type" => "application/json"
        }
      end

      def build_payload(messages, target_languages)
        tool = translation_tool(target_languages)
        {
          model: @model,
          messages: messages,
          tools: [tool],
          tool_choice: { type: "function", function: { name: tool[:function][:name] } }
        }
      end

      def system_prompt(target_languages)
        "You are a translation engine for i18n strings. " \
          "Translate the user message into each of: #{target_languages.join(", ")}. " \
          "You must call the translations tool and provide non-empty values for every locale key. " \
          "Preserve placeholders and formatting exactly (e.g., %{name}, {{count}}, %s). " \
          "If a locale cannot be translated, include an error message for that locale in errors."
      end

      def translation_tool(target_languages)
        locale_properties = target_languages.each_with_object({}) do |locale, hash|
          hash[locale] = {
            type: "string",
            description: "Translation for locale #{locale}."
          }
        end

        {
          type: "function",
          function: {
            name: "translations",
            description: "Return translations keyed by target locale, and optional per-locale errors.",
            parameters: {
              type: "object",
              properties: {
                translations: {
                  type: "object",
                  properties: locale_properties,
                  required: target_languages,
                  additionalProperties: false
                },
                errors: {
                  type: "object",
                  properties: locale_properties.merge(
                    "_request" => { type: "string", description: "Request-level error." }
                  ),
                  additionalProperties: false
                }
              },
              required: ["translations"]
            }
          }
        }
      end

      def tool_arguments_from(message)
        tool_call = message["tool_calls"]&.first
        arguments = tool_call&.dig("function", "arguments")
        return arguments if arguments

        function_call = message["function_call"]
        arguments = function_call&.dig("arguments")
        return arguments if arguments

        content = message["content"]
        return content if content && content.strip.start_with?("{")

        nil
      end

      def error_payload(message)
        { "translations" => {}, "errors" => { "_request" => message } }
      end

      def base_messages(text, target_languages)
        [
          {
            role: "system",
            content: system_prompt(target_languages)
          },
          {
            role: "user",
            content: text
          }
        ]
      end

      def retry_messages(messages, reason)
        messages + [
          {
            role: "user",
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
        unless retries.is_a?(Integer) && retries >= 0
          raise ArgumentError, "retries must be a non-negative integer"
        end

        retries
      end
    end
  end
end
