module Billing
  class Refund < ApplicationRecord
    self.table_name = "billing_refunds"
    belongs_to :payment, class_name: 'Billing::Payment'
    validates :reason, :idempotency_key, presence: true
    validates :idempotency_key, uniqueness: true
    validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
    validate do
      if payment && (payment.state != 'captured' || amount_cents.to_i + payment.refunds.where.not(id: id).sum(:amount_cents) > payment.amount_cents)
        errors.add(:amount_cents, 'exceeds refundable captured balance')
      end
    end
  end
end
