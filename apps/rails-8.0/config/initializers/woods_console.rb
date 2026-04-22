# frozen_string_literal: true

# Woods configuration for the testbed Rails app.
#
# Console MCP: blocks two table names to exercise the blocked-table mechanism.
# ERD: enabled so /woods/erd/schema.json is served from tmp/woods extraction output.
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_redacted_columns = %w[password password_digest encrypted_password]
  config.erd_enabled = true
  config.erd_path = '/woods/erd'
  config.erd_layers = %i[models controllers jobs mailers]
end
