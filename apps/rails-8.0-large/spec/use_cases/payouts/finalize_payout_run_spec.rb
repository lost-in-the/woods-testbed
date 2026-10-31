require 'rails_helper'

RSpec.describe Payouts::FinalizePayoutRun do
  before do
    setup_canopy
    rate_card(basis: 'flat', flat_cents: 5000)
  end

  def run_for(period = Date.current.beginning_of_month)
    Payouts::StartPayoutRun.new(author: @editor).call(organization: @organization, period_start: period)
  end

  def finalize(run)
    described_class.new(author: @editor).call(run)
  end

  it 'finalizing creates one transfer per draft statement and is idempotent' do
    individual_payee
    publish_article
    run = run_for
    expect { finalize(run) }.to change(Payouts::Transfer, :count).by(1)
      .and have_enqueued_job(Payouts::SubmitTransferJob).once
      .and have_enqueued_mail(ContributorMailer, :statement_ready).once
    expect { finalize(run) }.not_to change(Payouts::Transfer, :count)
    statement = run.statements.first.reload
    expect(statement.status).to eq('finalized')
    expect(run.reload.status).to eq('finalized')
    expect(statement.transfer).to be_a(Payouts::BankTransfer)
    expect(statement.transfer).to have_attributes(idempotency_key: "statement-#{statement.id}", amount_cents: 5000,
      account_last_four: '4321')
  end

  it 'sends agency statements to the agency with the agency account' do
    agency_payee(@writer)
    publish_article
    statement = finalize(run_for).statements.first
    expect(statement.transfer.account_last_four).to eq('7000')
  end

  it 'skips held statements' do
    individual_payee
    rate_card(basis: 'flat', flat_cents: 100, effective_on: Date.new(2026, 2, 1))
    publish_article
    expect { finalize(run_for) }.not_to change(Payouts::Transfer, :count)
  end

  it 'an author cannot finalize a run' do
    individual_payee
    publish_article
    run = run_for
    expect { described_class.new(author: @writer).call(run) }.to raise_error(Pundit::NotAuthorizedError)
  end
end
