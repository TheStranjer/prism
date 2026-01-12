# frozen_string_literal: true

require 'rspec'
require 'stringio'
require_relative '../lib/prism'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.before(:each) do
    Prism::Logging.output = StringIO.new
  end

  config.after(:each) do
    Prism::Logging.reset!
  end
end
