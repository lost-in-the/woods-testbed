module Billing
  class ChargePaymentJob < ApplicationJob
    queue_as :billing

    def perform(invoice_id)
      invoice = Billing::Invoice.find(invoice_id)
      payment = Billing::CardPayment.create!(
        invoice: invoice,
        amount_cents: invoice.total_cents,
        last_four: "4242"
      )
      payment.authorize!
      payment.capture!
    end
  end
end
