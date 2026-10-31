module Payouts
  # The only writer of payouts_earnings. The unique source index makes repeat
  # accruals no-ops, so callers can accrue from retries and listeners.
  class AccrueEarning
    def call(payee:, source:, kind:, amount_cents:, earned_on:, description:)
      return nil if amount_cents.to_i.zero?
      raise ArgumentError, 'Source belongs to another organization' unless organization_id_for(source) == payee.organization_id
      now = Time.current
      identity = { payee_id: payee.id, source_type: source.class.name, source_id: source.id, kind: Earning.kinds.fetch(kind.to_s) }
      Earning.insert_all([identity.merge(amount_cents: amount_cents, currency: payee.currency, earned_on: earned_on, description: description, created_at: now, updated_at: now)],
        unique_by: :index_payouts_earnings_on_source_identity)
      Earning.find_by!(identity)
    end

    private

    def organization_id_for(source)
      case source
      when Article then source.publication.organization_id
      when Syndication::License then source.partner.organization_id
      else raise ArgumentError, "Unsupported earning source #{source.class.name}"
      end
    end
  end
end
