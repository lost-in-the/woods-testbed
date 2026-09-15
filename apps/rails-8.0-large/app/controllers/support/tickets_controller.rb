module Support
  class TicketsController < ApplicationController
    before_action :require_session
    before_action :require_editor
    def index
      @tickets = scope.includes(:subscriber).order(id: :desc).limit(25).offset(page_offset)
    end
    def show
      @ticket = scope.find(params[:id])
    end
    def create
      subscriber = current_organization.subscribers.find(params.require(:subscriber_id))
      invoice = subscriber.invoices.find(params[:invoice_id]) if params[:invoice_id].present?
      ticket = subscriber.tickets.create!(title: params.require(:title), subject: invoice)
      redirect_to support_ticket_path(ticket)
    end
    def update
      ticket = scope.find(params[:id])
      ticket.update!(assignee: current_organization.authors.find(params[:assignee_id])) if params[:assignee_id].present?
      ticket.messages.create!(body: params[:body], author: current_author) if params[:body].present?
      ResolveTicket.new.call(ticket: ticket, author: current_author) if params[:resolve] == '1'
      redirect_to support_ticket_path(ticket)
    end
    private
    def scope = Ticket.joins(:subscriber).where(subscribers: { organization_id: current_organization.id })
  end
end
