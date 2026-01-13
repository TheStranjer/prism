# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

RSpec.describe Prism::GitHubClient do
  describe '#validate_token' do
    it 'returns true when token is valid with push permission for push delivery' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => true } }.to_json]
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be true
      stubs.verify_stubbed_calls
    end

    it 'returns true when token is valid with push and pull permissions for pull_request delivery' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => true } }.to_json]
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'pull_request')).to be true
      stubs.verify_stubbed_calls
    end

    it 'returns false when token does not exist (nil)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      github_client = described_class.new(token: nil, repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be false
    end

    it 'returns false when token is empty string' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      github_client = described_class.new(token: '   ', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be false
    end

    it 'returns false when token is expired (401 response)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [401, { 'Content-Type' => 'application/json' },
         { 'message' => 'Bad credentials' }.to_json]
      end

      github_client = described_class.new(token: 'expired_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when token does not grant push permission' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => false, 'pull' => true } }.to_json]
      end

      github_client = described_class.new(token: 'read_only_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns false when token does not grant pull permission for pull_request delivery' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => false } }.to_json]
      end

      github_client = described_class.new(token: 'limited_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'pull_request')).to be false
      stubs.verify_stubbed_calls
    end

    it 'returns true when token has push but no pull permission for push delivery' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => false } }.to_json]
      end

      github_client = described_class.new(token: 'push_only_token', repo_slug: 'org/repo', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be true
      stubs.verify_stubbed_calls
    end

    it 'returns false when repository does not exist (404 response)' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/nonexistent') do |_env|
        [404, { 'Content-Type' => 'application/json' },
         { 'message' => 'Not Found' }.to_json]
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/nonexistent', http_client: client)
      expect(github_client.validate_token(delivery_method: 'push')).to be false
      stubs.verify_stubbed_calls
    end
  end

  describe '#validate_token_with_reason' do
    it 'returns valid true when token has all required permissions' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => true } }.to_json]
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'pull_request')
      expect(result[:valid]).to be true
      expect(result[:reason]).to be_nil
      stubs.verify_stubbed_calls
    end

    it 'returns reason :missing when token is nil' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      github_client = described_class.new(token: nil, repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'push')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:missing)
    end

    it 'returns reason :expired when token returns 401' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [401, { 'Content-Type' => 'application/json' },
         { 'message' => 'Bad credentials' }.to_json]
      end

      github_client = described_class.new(token: 'expired_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'push')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:expired)
      stubs.verify_stubbed_calls
    end

    it 'returns reason :no_access when token returns 404' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [404, { 'Content-Type' => 'application/json' },
         { 'message' => 'Not Found' }.to_json]
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'push')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:no_access)
      stubs.verify_stubbed_calls
    end

    it 'returns reason :no_push_permission when push is false' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => false, 'pull' => true } }.to_json]
      end

      github_client = described_class.new(token: 'read_only_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'push')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:no_push_permission)
      stubs.verify_stubbed_calls
    end

    it 'returns reason :no_pull_request_permission when pull is false for pull_request delivery' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        [200, { 'Content-Type' => 'application/json' },
         { 'permissions' => { 'push' => true, 'pull' => false } }.to_json]
      end

      github_client = described_class.new(token: 'limited_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'pull_request')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:no_pull_request_permission)
      stubs.verify_stubbed_calls
    end

    it 'returns reason :error with message when exception occurs' do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Faraday.new(url: 'https://api.github.com') do |builder|
        builder.adapter :test, stubs
      end

      stubs.get('/repos/org/repo') do |_env|
        raise Faraday::ConnectionFailed, 'Connection refused'
      end

      github_client = described_class.new(token: 'valid_token', repo_slug: 'org/repo', http_client: client)
      result = github_client.validate_token_with_reason(delivery_method: 'push')
      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:error)
      expect(result[:message]).to include('Connection refused')
    end
  end
end
