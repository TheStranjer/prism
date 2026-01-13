# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

RSpec.describe Prism::Engines::ChatGPT do
  it 'builds a tool-call request and parses translations' do
    stubs = Faraday::Adapter::Test::Stubs.new
    client = Faraday.new do |builder|
      builder.adapter :test, stubs
    end

    response_body = {
      'choices' => [
        {
          'message' => {
            'tool_calls' => [
              {
                'function' => {
                  'arguments' => { 'translations' => { 'fr' => 'Bonjour' } }.to_json
                }
              }
            ]
          }
        }
      ]
    }

    stubs.post('https://api.openai.com/v1/chat/completions') do |env|
      body = JSON.parse(env.body)
      expect(body['messages'][0]['role']).to eq('system')
      expect(body['messages'][1]['role']).to eq('user')
      expect(body['messages'][1]['content']).to eq('Hello')
      expect(body['tool_choice']['function']['name']).to eq('translations')
      [200, { 'Content-Type' => 'application/json' }, response_body.to_json]
    end

    engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
    result = engine.get_translations('Hello', ['fr'])

    expect(result).to eq({ 'translations' => { 'fr' => 'Bonjour' } })
    stubs.verify_stubbed_calls
  end

  describe '#generate_commit_content' do
    it 'generates commit message for push delivery method with both source and staged diffs' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      response_body = {
        'choices' => [
          {
            'message' => {
              'tool_calls' => [
                {
                  'function' => {
                    'arguments' => { 'commit_message' => 'Add French translations for greeting' }.to_json
                  }
                }
              ]
            }
          }
        ]
      }

      stubs.post('https://api.openai.com/v1/chat/completions') do |env|
        body = JSON.parse(env.body)
        expect(body['messages'].length).to eq(3)
        expect(body['messages'][0]['role']).to eq('system')
        expect(body['messages'][0]['content']).to include('commit message generator')
        expect(body['messages'][0]['content']).to include('original commit')
        expect(body['messages'][0]['content']).to include('staged translation changes')
        expect(body['messages'][0]['content']).not_to include('Also write a pull request')
        expect(body['messages'][1]['role']).to eq('user')
        expect(body['messages'][1]['content']).to include('original commit that triggered')
        expect(body['messages'][1]['content']).to include('commit abc123')
        expect(body['messages'][2]['role']).to eq('user')
        expect(body['messages'][2]['content']).to include('staged translation changes')
        expect(body['messages'][2]['content']).to include('diff --git a/locales/fr.json')
        expect(body['tool_choice']['function']['name']).to eq('push_commit')
        [200, { 'Content-Type' => 'application/json' }, response_body.to_json]
      end

      engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
      result = engine.generate_commit_content(
        source_commit_diff: "commit abc123\n\nUpdate greeting text",
        staged_diff: 'diff --git a/locales/fr.json',
        delivery_method: 'push'
      )

      expect(result).to eq({ 'commit_message' => 'Add French translations for greeting' })
      stubs.verify_stubbed_calls
    end

    it 'generates commit message, PR title, and PR description for pull_request delivery method' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      response_body = {
        'choices' => [
          {
            'message' => {
              'tool_calls' => [
                {
                  'function' => {
                    'arguments' => {
                      'commit_message' => 'Add French translations for greeting',
                      'pr_title' => 'Update translations for greeting changes',
                      'pr_description' => 'This PR adds French translations.'
                    }.to_json
                  }
                }
              ]
            }
          }
        ]
      }

      stubs.post('https://api.openai.com/v1/chat/completions') do |env|
        body = JSON.parse(env.body)
        expect(body['messages'].length).to eq(3)
        expect(body['messages'][0]['role']).to eq('system')
        expect(body['messages'][0]['content']).to include('commit message generator')
        expect(body['messages'][0]['content']).to include('Also write a pull request')
        expect(body['messages'][1]['role']).to eq('user')
        expect(body['messages'][1]['content']).to include('original commit that triggered')
        expect(body['messages'][2]['role']).to eq('user')
        expect(body['messages'][2]['content']).to include('staged translation changes')
        expect(body['tool_choice']['function']['name']).to eq('pull_request_commit')
        [200, { 'Content-Type' => 'application/json' }, response_body.to_json]
      end

      engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
      result = engine.generate_commit_content(
        source_commit_diff: "commit abc123\n\nUpdate greeting text",
        staged_diff: 'diff --git a/locales/fr.json',
        delivery_method: 'pull_request'
      )

      expect(result).to eq({
                             'commit_message' => 'Add French translations for greeting',
                             'pr_title' => 'Update translations for greeting changes',
                             'pr_description' => 'This PR adds French translations.'
                           })
      stubs.verify_stubbed_calls
    end

    it 'raises error when commit_message is missing for push' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      response_body = {
        'choices' => [
          {
            'message' => {
              'tool_calls' => [
                {
                  'function' => {
                    'arguments' => {}.to_json
                  }
                }
              ]
            }
          }
        ]
      }

      stubs.post('https://api.openai.com/v1/chat/completions') do |_env|
        [200, { 'Content-Type' => 'application/json' }, response_body.to_json]
      end

      engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
      expect do
        engine.generate_commit_content(
          source_commit_diff: 'commit abc',
          staged_diff: 'diff',
          delivery_method: 'push'
        )
      end.to raise_error(/Missing or empty commit_message/)
    end

    it 'raises error when pr_title is missing for pull_request' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      response_body = {
        'choices' => [
          {
            'message' => {
              'tool_calls' => [
                {
                  'function' => {
                    'arguments' => {
                      'commit_message' => 'Add translations',
                      'pr_description' => 'Description'
                    }.to_json
                  }
                }
              ]
            }
          }
        ]
      }

      stubs.post('https://api.openai.com/v1/chat/completions') do |_env|
        [200, { 'Content-Type' => 'application/json' }, response_body.to_json]
      end

      engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
      expect do
        engine.generate_commit_content(
          source_commit_diff: 'commit abc',
          staged_diff: 'diff',
          delivery_method: 'pull_request'
        )
      end.to raise_error(/Missing or empty pr_title/)
    end

    it 'raises error on HTTP failure' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.post('https://api.openai.com/v1/chat/completions') do |_env|
        [500, { 'Content-Type' => 'application/json' }, 'Internal Server Error']
      end

      engine = described_class.new(api_token: 'token', model: 'gpt-4o-mini', http_client: client)
      expect do
        engine.generate_commit_content(
          source_commit_diff: 'commit abc',
          staged_diff: 'diff',
          delivery_method: 'push'
        )
      end.to raise_error(/HTTP 500/)
    end
  end

  describe '#validate_token' do
    it 'returns true when token is valid and model is available' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'data' => [{ 'id' => 'gpt-4o-mini' }, { 'id' => 'gpt-4' }] }.to_json]
      end

      engine = described_class.new(api_token: 'valid_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be true
      stubs.verify_stubbed_calls
    end

    it 'returns false when model is not in available models' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'data' => [{ 'id' => 'gpt-4' }, { 'id' => 'gpt-3.5-turbo' }] }.to_json]
      end

      engine = described_class.new(api_token: 'valid_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when token does not exist (nil)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      engine = described_class.new(api_token: nil, model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
    end

    it 'returns false when token is empty string' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      engine = described_class.new(api_token: '   ', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
    end

    it 'returns false when token is expired (401 response)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        [401, { 'Content-Type' => 'application/json' }, { 'error' => { 'message' => 'Invalid API key' } }.to_json]
      end

      engine = described_class.new(api_token: 'expired_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when token does not allow completions (403 response)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        [403, { 'Content-Type' => 'application/json' }, { 'error' => { 'message' => 'Access denied' } }.to_json]
      end

      engine = described_class.new(api_token: 'restricted_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when API returns server error' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        [500, { 'Content-Type' => 'application/json' }, 'Internal Server Error']
      end

      engine = described_class.new(api_token: 'valid_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when network error occurs' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('https://api.openai.com/v1/models') do |_env|
        raise Faraday::ConnectionFailed, 'Connection refused'
      end

      engine = described_class.new(api_token: 'valid_token', model: 'gpt-4o-mini', http_client: client)
      expect(engine.validate_token).to be false
    end
  end
end
