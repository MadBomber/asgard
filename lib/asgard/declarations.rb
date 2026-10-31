# frozen_string_literal: true

module Asgard
  # What `schedule` and `watch` share: a registry of declared entries,
  # keyed by entry name.
  module Declarations
    module_function

    # Stores +spec+ (a Hash with a :name) in +declarations+ and returns it.
    # An identical entry already there is a no-op (a .loki file loaded
    # twice); a different one under the same name is an error that names
    # +kind+ ("schedule", "watch").
    def record(declarations, spec, kind)
      name  = spec[:name]
      taken = declarations[name]
      raise ArgumentError, "#{kind}: #{name.inspect} is already declared; give one a distinct as: name" if taken && taken != spec

      declarations[name] = spec
    end
  end
end
