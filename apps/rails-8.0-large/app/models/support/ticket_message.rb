module Support
  class TicketMessage < ApplicationRecord
    self.table_name = "support_ticket_messages"
    belongs_to :ticket, class_name: 'Support::Ticket'
    belongs_to :author, optional: true
    validates :body, presence: true
    validate { errors.add(:author, 'must belong to organization') if author && !author.memberships.exists?(organization_id: ticket&.subscriber&.organization_id) }
  end
end
