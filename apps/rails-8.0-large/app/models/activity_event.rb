class ActivityEvent < ApplicationRecord
  belongs_to :organization
  belongs_to :actor, class_name: 'Author', optional: true
  belongs_to :subject, polymorphic: true
  has_many :webhook_deliveries, dependent: :destroy
  validates :action, presence: true
  validates :subject_type, inclusion: { in: ['Article', 'Billing::Subscription', 'Support::Ticket'] }
  validate do
    owner = case subject
    when Article then subject.publication.organization_id
    when Billing::Subscription, Support::Ticket then subject.subscriber.organization_id
    end
    errors.add(:subject, 'wrong organization') unless owner == organization_id
    errors.add(:actor, 'wrong organization') if actor && !actor.memberships.exists?(organization_id: organization_id)
  end
end
