module Payouts
  # Deterministic stand-in for a payment provider. No network is used.
  class FakeLedgerClient
    class Rejected < StandardError; end
    class TransientError < StandardError; end

    def create_transfer(idempotency_key:, amount_cents:, currency:, destination:, attempt:)
      raise Rejected, 'Destination account was rejected' if destination['account_last_four'] == '0000'
      raise TransientError, 'Ledger timed out' if attempt == 1 && destination['simulate_timeout'].present?
      { reference: "ldg_#{Digest::SHA256.hexdigest(idempotency_key)[0, 12]}", status: 'settled' }
    end
  end
end
