module Billing
  class ChargePaymentJob < ApplicationJob
    queue_as :billing
    def perform(invoice_id, key = nil, outcome = 'success')
      Billing::CollectPayment.new.call(invoice: Billing::Invoice.find(invoice_id), key: key || "invoice-#{invoice_id}-initial", outcome: outcome)
    end
  end
end
