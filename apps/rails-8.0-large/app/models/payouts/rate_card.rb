module Payouts
  class RateCard < ApplicationRecord
    self.table_name = 'payouts_rate_cards'
    belongs_to :publication
    enum :basis, { per_word: 0, flat: 1, revenue_share: 2 }
    store_accessor :terms, :cents_per_word, :flat_cents, :minimum_cents
    validates :effective_on, presence: true, uniqueness: { scope: :publication_id }

    %i[cents_per_word flat_cents minimum_cents].each do |term|
      define_method(term) { super()&.to_i }
    end

    def self.current_for(publication, on:)
      where(publication: publication).where('effective_on <= ?', on).order(effective_on: :desc).first
    end
  end
end
