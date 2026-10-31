# frozen_string_literal: true

require_relative "jobs/declaration"
require_relative "jobs/state"
require_relative "jobs/launcher"
require_relative "jobs/stopper"
require_relative "jobs/commands"

module Asgard
  # Background jobs started from a task body:
  #
  #   class Tasks
  #     def doc_server = sh "mkdocs serve", background: true   # doc_server-1
  #     def servers
  #       sh "docker compose up postgres", background: true     # servers-1
  #       sh "bin/rails server",            background: :api    # api
  #     end
  #   end
  #
  # then manage them with `asgard jobs list|stop|log|restart|clean`.
  module Jobs
    # A job could not be managed: an unknown name, no owning task.
    class Error < Asgard::Error; end
  end
end
