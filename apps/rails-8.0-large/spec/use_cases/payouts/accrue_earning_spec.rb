require 'rails_helper'

RSpec.describe Payouts::AccrueEarning do
  before do
    setup_canopy
    publish_article
    @payee = individual_payee
  end

  def accrue(**overrides)
    described_class.new.call(payee: @payee, source: @article, kind: :article_fee, amount_cents: 1200,
      earned_on: Date.new(2026, 8, 3), description: 'Story fee', **overrides)
  end

  it 'records one earning for repeated calls' do
    expect { 2.times { accrue } }.to change(Payouts::Earning, :count).by(1)
    expect(accrue).to have_attributes(amount_cents: 1200, kind: 'article_fee', source: @article)
  end

  it 'skips zero amounts' do
    expect(accrue(amount_cents: 0)).to be_nil
    expect(Payouts::Earning.count).to eq(0)
  end

  it 'refuses a source from another organization' do
    other = Organization.create!(name: 'Other', slug: "other-#{SecureRandom.hex(3)}")
    @payee.update_column(:organization_id, other.id)
    expect { accrue }.to raise_error(ArgumentError, 'Source belongs to another organization')
  end
end
