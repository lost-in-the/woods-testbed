require 'rails_helper'

RSpec.describe Payouts::AccrueArticleEarning do
  before { setup_canopy }

  it 'publishing twice accrues one article earning' do
    individual_payee
    rate_card
    approve_article
    publisher = PublishArticle.new(author: @editor)
    expect { 2.times { publisher.call(@article) } }.to change(Payouts::Earning, :count).by(1)
    expect(Payouts::Earning.last).to have_attributes(kind: 'article_fee', amount_cents: @article.reload.word_count * 4,
      earned_on: @article.published_at.to_date)
    expect { 2.times { described_class.new.call(@article) } }.not_to change(Payouts::Earning, :count)
  end

  it 'publishing for an author without a payee accrues nothing' do
    rate_card
    expect { publish_article }.not_to change(Payouts::Earning, :count)
    expect(@article.reload.state).to eq('published')
  end

  it 'accrues nothing without a rate card' do
    individual_payee
    expect { publish_article }.not_to change(Payouts::Earning, :count)
  end

  it 'credits the agency payee for a represented author' do
    agency = agency_payee(@writer)
    rate_card
    publish_article
    expect(Payouts::Earning.last.payee).to eq(agency)
  end
end
