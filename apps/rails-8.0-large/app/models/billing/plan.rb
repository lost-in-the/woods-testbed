module Billing
  class Plan < ApplicationRecord
    self.table_name = "billing_plans"
    belongs_to :publication
    has_many :subscriptions, class_name: 'Billing::Subscription', dependent: :restrict_with_error
    validates :name, presence: true
    validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, inclusion: { in: ['USD'] }
  end
end
