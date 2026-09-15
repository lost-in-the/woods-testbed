module Support
  class Ticket < ApplicationRecord
    self.table_name = "support_tickets"
    belongs_to :subscriber
    belongs_to :assignee, class_name: 'Author', optional: true
    belongs_to :subject, polymorphic: true, optional: true
    has_many :messages, class_name: 'Support::TicketMessage', dependent: :destroy
    validates :title, presence: true
    validates :state, inclusion: { in: %w[open resolved] }
    validates :subject_type, inclusion: { in: ['Billing::Invoice', 'Billing::Subscription'], allow_nil: true }
    validate do
      errors.add(:subject, 'must belong to subscriber') if subject && (!subject.respond_to?(:subscriber_id) || subject.subscriber_id != subscriber_id)
      errors.add(:assignee, 'must be an organization editor') if assignee && !assignee.memberships.exists?(organization_id: subscriber&.organization_id, role: 'editor')
    end
  end
end
