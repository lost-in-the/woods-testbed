# frozen_string_literal: true

# Woods configuration for the testbed Rails app.
#
# Console MCP is enabled without a token on purpose: the testbed is a
# throwaway host, and the gem warns at boot that the endpoint is
# unauthenticated. Never copy this initializer into a real app.
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_redacted_columns = %w[password password_digest encrypted_password]
end
