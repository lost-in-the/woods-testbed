require 'rails_helper'

RSpec.describe Payouts::StartPayoutRun do
  before do
    setup_canopy
    @payee = individual_payee
    @period = Date.current.beginning_of_month
  end

  def start(author: @editor, period: @period + 9)
    described_class.new(author: author).call(organization: @organization, period_start: period)
  end

  def publish_with(**terms)
    rate_card(basis: 'flat', **terms)
    publish_article
  end

  it 'a second run for the same month builds nothing' do
    publish_with(flat_cents: 5000)
    first = nil
    expect { first = start }.to change(Payouts::PayoutRun, :count).by(1).and change(Payouts::Statement, :count).by(1)
    expect { expect(start).to eq(first) }.not_to change { [Payouts::PayoutRun.count, Payouts::Statement.count] }
    expect(first.period_start).to eq(@period)
    expect(first.statements.first).to have_attributes(status: 'draft', total_cents: 5000, payee: @payee)
    expect(Payouts::Earning.last.statement).to eq(first.statements.first)
  end

  it 'does not pick up earnings that arrive after the first run' do
    publish_with(flat_cents: 5000)
    run = start
    other = Article.create!(author: @writer, publication: @publication, title: 'Later', body: 'More words here')
    Payouts::AccrueEarning.new.call(payee: @payee, source: other, kind: :article_fee, amount_cents: 700, earned_on: @period, description: 'Late')
    start
    expect(run.statements.sum(:total_cents)).to eq(5000)
    expect(Payouts::Earning.unclaimed.count).to eq(1)
  end

  it 'a statement below the minimum is held and its earnings roll into next month' do
    publish_with(flat_cents: 1000)
    run = start
    statement = run.statements.first
    expect(statement).to have_attributes(status: 'held', hold_reason: 'below_minimum', total_cents: 1000)
    expect(Payouts::Earning.last.statement_id).to be_nil

    other = Article.create!(author: @writer, publication: @publication, title: 'Next', body: 'Words')
    Payouts::AccrueEarning.new.call(payee: @payee, source: other, kind: :article_fee, amount_cents: 2000,
      earned_on: @period.next_month, description: 'Next fee')
    next_run = start(period: @period.next_month)
    expect(next_run.statements.first).to have_attributes(status: 'draft', total_cents: 3000)
    expect(Payouts::Earning.unclaimed).to be_empty
  end

  it 'leaves out earnings from later months' do
    publish_with(flat_cents: 5000)
    run = start(period: @period.prev_month)
    expect(run.statements).to be_empty
    expect(Payouts::Earning.unclaimed.count).to eq(1)
  end

  it 'an author cannot start a payout run' do
    expect { start(author: @writer) }.to raise_error(Pundit::NotAuthorizedError)
    expect(Payouts::PayoutRun.count).to eq(0)
  end

  it 'paused payees get no statement and keep their earnings' do
    publish_with(flat_cents: 5000)
    @payee.paused!
    expect(start.statements).to be_empty
    expect(Payouts::Earning.where(payee: @payee).unclaimed.count).to eq(1)
  end
end
