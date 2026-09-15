module Billing
  # Deterministic local adapter: a failed attempt remains a failed attempt.
  # Retrying delivery uses the same key; retrying a declined card uses a new key.
  class CollectPayment
    def call(invoice:, key:, outcome: 'success', method: 'card')
      raise ArgumentError, 'Unknown payment outcome' unless %w[success failure].include?(outcome)
      raise ArgumentError, 'An idempotency key is required' if key.blank?
      invoice.with_lock do
        existing = Payment.find_by(idempotency_key: key)
        if existing
          raise ArgumentError, 'Key belongs to another invoice' unless existing.invoice_id == invoice.id
          return existing
        end
        return invoice.payments.find_by!(state: 'captured') if invoice.settled_at
        attributes = { invoice: invoice, amount_cents: invoice.total_cents, idempotency_key: key }
        payment = method == 'bank' ? BankPayment.create!(**attributes, sort_code: '000000') : CardPayment.create!(**attributes, last_four: '4242')
        if outcome == 'failure'
          payment.fail!
        else
          payment.authorize!
          payment.capture!
          invoice.update!(settled_at: Time.current)
        end
        payment
      end
    end
  end
end
