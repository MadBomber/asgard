# frozen_string_literal: true

# Required first: Asgard::Schedule::Error subclasses Asgard::Error.
module Asgard
  class Error < StandardError; end
  class CircularDependencyError < Error; end
end
