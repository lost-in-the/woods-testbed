class EngagementEvent < ApplicationRecord
  belongs_to :subscriber
  belongs_to :article
  belongs_to :delivery, class_name: 'Newsletter::Delivery', optional: true
  validates :kind, inclusion: { in: %w[open click read] }
  validate do
    errors.add(:subscriber, 'wrong organization') unless subscriber&.organization_id == article&.publication&.organization_id
    errors.add(:delivery, 'does not match subscriber/article') if delivery && (delivery.subscriber_id != subscriber_id || delivery.campaign.article_id != article_id)
  end
end
