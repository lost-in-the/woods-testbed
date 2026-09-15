module Billing
  class Subscription < ApplicationRecord
    self.table_name = "billing_subscriptions"
    belongs_to :subscriber
    belongs_to :plan, class_name: 'Billing::Plan'
    has_many :invoices, class_name: 'Billing::Invoice', dependent: :restrict_with_error
    has_many :history, class_name: 'Billing::SubscriptionChange', dependent: :destroy
    validates :state, inclusion: { in: %w[active canceled] }
    validates :renews_at, presence: true
    validates :subscriber_id, uniqueness: { scope: :plan_id }
    scope :active, -> { where(state: 'active') }
    validate { errors.add(:plan, 'must belong to the subscriber organization') unless plan&.publication&.organization_id == subscriber&.organization_id }
  end
end
