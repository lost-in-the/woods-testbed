require_relative "boot"

require "rails"
# Selectively required railties: this variant has no asset pipeline and no JS
# bundler. Everything it omits is something the generated tree would otherwise
# multiply, and boot time is a term in every number this variant exists to
# measure.
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module RailsEightLarge
  class Application < Rails::Application
    config.load_defaults 8.0
    config.api_only = false

    # The generated tree lands under app/generated and is gitignored. It is a
    # normal autoload path — extraction must see it exactly as it sees
    # hand-written code, or the scale measurement measures the wrong thing.
    config.autoload_lib(ignore: %w[tasks]) if config.respond_to?(:autoload_lib)
  end
end
