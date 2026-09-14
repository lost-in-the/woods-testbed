require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.hosts.clear
  config.action_controller.allow_forgery_protection = false
  config.active_job.queue_adapter = :test
  config.consider_all_requests_local = true
  config.action_mailer.delivery_method = :test
end
