module Canopy
  # Contributor pay rules. Reached from accrual and from the statement preview.
  class RoyaltyCalculator
    def initialize(rate_card: nil, settings: Rails.configuration.payouts)
      @rate_card = rate_card
      @settings = settings
    end

    def article_fee_cents(word_count:)
      case @rate_card&.basis.to_s
      when 'per_word' then [word_count * @rate_card.cents_per_word.to_i, @rate_card.minimum_cents.to_i].max
      when 'flat' then @rate_card.flat_cents.to_i
      else 0
      end
    end

    def syndication_share_cents(fee_cents:)
      fee_cents.to_i * @settings.fetch(:syndication_author_share_bps) / 10_000
    end

    def breakdown(earnings)
      earnings.group_by { |earning| earning.kind.to_s }.sort.map do |kind, rows|
        { kind: kind, count: rows.size, gross_cents: rows.sum(&:amount_cents) }
      end
    end
  end
end
