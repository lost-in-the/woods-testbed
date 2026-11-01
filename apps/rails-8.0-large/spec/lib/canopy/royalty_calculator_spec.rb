require 'rails_helper'

RSpec.describe Canopy::RoyaltyCalculator do
  let(:card) { Struct.new(:basis, :cents_per_word, :flat_cents, :minimum_cents, keyword_init: true) }
  let(:earning) { Struct.new(:kind, :amount_cents) }

  it 'pays per word, raised to the minimum when one is set' do
    expect(described_class.new(rate_card: card.new(basis: 'per_word', cents_per_word: 4)).article_fee_cents(word_count: 300)).to eq(1200)
    expect(described_class.new(rate_card: card.new(basis: 'per_word', cents_per_word: 4, minimum_cents: 2000)).article_fee_cents(word_count: 300)).to eq(2000)
  end

  it 'pays a flat fee, and nothing up front for revenue share' do
    expect(described_class.new(rate_card: card.new(basis: 'flat', flat_cents: 5000)).article_fee_cents(word_count: 10)).to eq(5000)
    expect(described_class.new(rate_card: card.new(basis: 'revenue_share')).article_fee_cents(word_count: 300)).to eq(0)
  end

  it 'gives the author the configured share of a license fee, rounded down' do
    expect(described_class.new.syndication_share_cents(fee_cents: 10_001)).to eq(5000)
  end

  it 'groups earnings by kind' do
    rows = [earning.new('article_fee', 100), earning.new('syndication_share', 50), earning.new('article_fee', 200)]
    expect(described_class.new.breakdown(rows)).to eq([
      { kind: 'article_fee', count: 2, gross_cents: 300 },
      { kind: 'syndication_share', count: 1, gross_cents: 50 }
    ])
  end
end
