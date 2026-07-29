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

    config.autoload_lib(ignore: %w[tasks]) if config.respond_to?(:autoload_lib)

    # ── The generated tree (scripts/generate_large_app.rb) ────────────────
    #
    # It is emitted into the REAL directories — app/models/generated,
    # app/use_cases/generated, app/views/generated — rather than one tidy
    # app/generated tree, because the file-based extractors scan fixed
    # directory lists and would never look inside the latter.
    #
    # Zeitwerk would read `generated/` as a namespace segment, so these are
    # collapsed: app/models/generated/beacon_0.rb defines Beacon0, not
    # Generated::Beacon0. Extraction must see generated code exactly as it sees
    # hand-written code or the scale measurement measures the wrong thing.
    generated_dirs = Dir[Rails.root.join("app/*/generated"), Rails.root.join("app/models/concerns/generated")]
    config.autoloader = :zeitwerk
    Rails.autoloaders.main.collapse(generated_dirs) if generated_dirs.any?

    # Generated routes are drawn from their own file, and generated tables come
    # from their own migration directory. Both are absent until the generator
    # runs, so both are guarded.
    generated_routes = Rails.root.join("config/routes_generated.rb")
    config.paths["config/routes.rb"] << generated_routes.to_s if generated_routes.exist?

    generated_migrate = Rails.root.join("db/generated/migrate")
    config.paths["db/migrate"] << generated_migrate.to_s if generated_migrate.exist?
  end
end
