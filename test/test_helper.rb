# frozen_string_literal: true

unless defined?(SimpleCov)
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    minimum_coverage 95
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "asgard"

require "minitest/autorun"
