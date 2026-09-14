module Billing
  class RefundPayment
    def call(payment:, amount_cents:, key:, reason:)
      payment.with_lock do
        existing = Refund.find_by(idempotency_key: key)
        if existing
          raise ArgumentError, 'Key belongs to a different refund' unless existing.payment_id == payment.id && existing.amount_cents == amount_cents.to_i
          return existing
        end
        payment.refunds.create!(amount_cents: amount_cents, reason: reason, idempotency_key: key)
      end
    end
  end
end
