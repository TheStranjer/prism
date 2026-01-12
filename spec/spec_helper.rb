# frozen_string_literal: true

require 'rspec'
require_relative '../lib/prism'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
