class WebhookDelivery < ApplicationRecord
  belongs_to :webhook_endpoint
  belongs_to :activity_event
  validates :activity_event_id, uniqueness: { scope: :webhook_endpoint_id }
  validates :state, inclusion: { in: %w[pending failed delivered] }
  validate { errors.add(:activity_event, 'wrong organization') unless activity_event&.organization_id == webhook_endpoint&.organization_id }
end
