# frozen_string_literal: true

# Configure a documented renderer before loading the actual packaged executable.
# This does not boot Rails or replace the MCP server/transport.
require 'woods'
Woods.configuration.context_format = :json
