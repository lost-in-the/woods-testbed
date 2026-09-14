module Billing
  class InvoicesController < ApplicationController
    include RequiresAuthor
    before_action :require_session
    before_action :require_editor
    def index
      @invoices = scope.includes(:subscriber).order(id: :desc).limit(25).offset(page_offset)
    end
    def show
      @invoice = scope.find(params[:id])
    end
    def pay
      invoice = scope.find(params[:id])
      CollectPayment.new.call(invoice: invoice, key: params.require(:key), outcome: params.fetch(:outcome, 'success'), method: params[:method])
      redirect_to billing_invoice_path(invoice)
    end
    def refund
      invoice = scope.find(params[:id])
      RefundPayment.new.call(payment: invoice.payments.find(params[:payment_id]), amount_cents: params.require(:amount_cents), key: params.require(:key), reason: params.require(:reason))
      redirect_to billing_invoice_path(invoice)
    end
    private
    def scope
      Invoice.joins(:subscriber).where(subscribers: { organization_id: current_organization.id })
    end
  end
end
