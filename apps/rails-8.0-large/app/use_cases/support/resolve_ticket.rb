module Support
  class ResolveTicket
    def call(ticket:, author:)
      raise Pundit::NotAuthorizedError unless author&.editor_of?(ticket.subscriber.organization)
      ticket.with_lock do
        return if ticket.state == 'resolved'
        ticket.update!(state: 'resolved', assignee: author)
        RecordActivity.new.call(organization: ticket.subscriber.organization, actor: author, subject: ticket, action: 'ticket.resolved')
      end
    end
  end
end
