module Billing
  class InvoicesController < ApplicationController
    include RequiresAuthor

    def index
      @invoices = Billing::Invoice.outstanding.not_archived
    end

    def show
      @invoice = Billing::Invoice.find(params[:id])
    end
  end
end
