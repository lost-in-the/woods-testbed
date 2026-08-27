# frozen_string_literal: true

# Woods configuration for the testbed Rails app.
#
# Console MCP is enabled here. The bearer token comes from
# WOODS_CONSOLE_MCP_TOKEN, which docker-compose.yml sets to a fixed
# test-only value; without it the gem refuses every guarded request with
# 401. Never copy that token, or this initializer, into a real app.
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_redacted_columns = %w[password password_digest encrypted_password]
end
