require_relative "boot"

require "rails"
# Selectively require the railties this minimal app needs — no asset pipeline
# or JS bundler, which keeps the Rails 6.0 boot small and dependency-light while
# still exercising the version-sensitive extraction path (models, controllers,
# jobs, mailers, routes).
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module RailsSixZero
  class Application < Rails::Application
    config.load_defaults 6.0
    config.api_only = false
  end
end
