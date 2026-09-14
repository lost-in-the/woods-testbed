class Subscriber < ApplicationRecord
  belongs_to :organization
  belongs_to :author, optional: true
  has_many :subscriptions, class_name: 'Billing::Subscription', dependent: :restrict_with_error
  has_many :invoices, class_name: 'Billing::Invoice', dependent: :restrict_with_error
  has_many :tickets, class_name: 'Support::Ticket', dependent: :destroy
  validates :name, :email, presence: true
  validates :email, uniqueness: { scope: :organization_id }
  validate { errors.add(:author, 'must belong to the organization') if author && !author.memberships.exists?(organization_id: organization_id) }
end
