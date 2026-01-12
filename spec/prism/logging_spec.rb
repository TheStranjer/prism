# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Prism::Logging do
  after do
    described_class.reset!
  end

  describe '.log' do
    it 'writes to the configured output stream' do
      output = StringIO.new
      described_class.output = output

      described_class.log('test message')

      expect(output.string).to eq("test message\n")
    end

    it 'flushes the output stream after writing' do
      output = StringIO.new
      described_class.output = output

      allow(output).to receive(:flush).and_call_original

      described_class.log('test message')

      expect(output).to have_received(:flush)
    end

    it 'writes to $stdout by default when no output is configured' do
      described_class.reset!

      expect { described_class.log('stdout message') }.to output("stdout message\n").to_stdout
    end

    it 'handles multiple log calls' do
      output = StringIO.new
      described_class.output = output

      described_class.log('first')
      described_class.log('second')

      expect(output.string).to eq("first\nsecond\n")
    end
  end

  describe '.reset!' do
    it 'clears the configured output' do
      described_class.output = StringIO.new
      described_class.reset!

      expect(described_class.output).to be_nil
    end
  end
end
