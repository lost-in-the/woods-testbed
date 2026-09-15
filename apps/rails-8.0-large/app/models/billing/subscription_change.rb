module Billing
  class SubscriptionChange < ApplicationRecord
    self.table_name = "billing_subscription_changes"
    belongs_to :subscription, class_name: 'Billing::Subscription'
    validates :event, presence: true
  end
end
