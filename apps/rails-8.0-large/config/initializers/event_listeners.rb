Rails.application.config.after_initialize { PayoutsListener.subscribe! }
