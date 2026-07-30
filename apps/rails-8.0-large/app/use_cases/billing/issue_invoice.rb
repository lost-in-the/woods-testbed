module Billing
  class IssueInvoice
    def initialize(author:)
      @author = author
    end

    def call(description:, amount_cents:)
      invoice = Billing::Invoice.create!(author: @author, reference: next_reference)
      invoice.line_items.create!(description: description, amount_cents: amount_cents)
      Billing::ChargePaymentJob.perform_later(invoice.id)
      invoice
    end

    private

    def next_reference
      "INV-#{SecureRandom.hex(4).upcase}"
    end
  end
end
