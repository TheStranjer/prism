# frozen_string_literal: true

require "spec_helper"

RSpec.describe Prism::LocaleFile do
  it "infers root locale and flattens strings" do
    data = { "en" => { "greeting" => "Hello", "home" => { "title" => "Home" } } }
    locale = described_class.new(data, locale_hint: "en")

    expect(locale.root_key).to eq("en")
    expect(locale.flattened_strings).to eq({ "greeting" => "Hello", "home.title" => "Home" })
  end

  it "sets nested values" do
    locale = described_class.new({ "en" => {} }, locale_hint: "en")
    locale.set_value("home.title", "Homepage")

    expect(locale.to_serialized(:json)).to include("Homepage")
  end
end
