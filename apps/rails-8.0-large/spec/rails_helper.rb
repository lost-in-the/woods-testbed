ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rspec/rails"

require_relative 'support/canopy_context'
ActiveRecord::Migration.maintain_test_schema!
RSpec.configure do |config|
  config.include CanopyContext
  config.include ActiveSupport::Testing::TimeHelpers
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
end
