module Newsletter
  class Delivery < ApplicationRecord
    self.table_name = "newsletter_deliveries"
    belongs_to :campaign, class_name: 'Newsletter::Campaign'
    belongs_to :subscriber
    has_many :engagement_events, foreign_key: :delivery_id, dependent: :destroy
    validates :subscriber_id, uniqueness: { scope: :campaign_id }
    validates :state, inclusion: { in: %w[queued delivered bounced] }
    validate { errors.add(:subscriber, 'must belong to the organization') unless subscriber&.organization_id == campaign&.publication&.organization_id }
  end
end
