require 'rails_helper'

RSpec.describe Payouts::SubmitTransfer do
  before do
    setup_canopy
    rate_card(basis: 'flat', flat_cents: 5000)
  end

  def transfer_for(**bank_details)
    individual_payee(**bank_details)
    publish_article
    run = Payouts::StartPayoutRun.new(author: @editor).call(organization: @organization, period_start: Date.current.beginning_of_month)
    Payouts::FinalizePayoutRun.new(author: @editor).call(run).statements.first.transfer
  end

  it 'a timeout fails the first attempt and the retry settles once' do
    transfer = transfer_for(simulate_timeout: '1')
    expect { described_class.new.call(transfer) }.to raise_error(Payouts::FakeLedgerClient::TransientError)
    transfer.reload
    expect(transfer).to have_attributes(state: 'failed', attempts: 1)
    expect(transfer.last_error).to be_present
    expect(transfer.statement.reload.status).to eq('finalized')

    described_class.new.call(transfer)
    transfer.reload
    expect(transfer).to have_attributes(state: 'settled', attempts: 2)
    expect(transfer.provider_reference).to eq("ldg_#{Digest::SHA256.hexdigest(transfer.idempotency_key)[0, 12]}")
    expect(transfer.statement.reload.status).to eq('paid')
    expect(transfer.statement.payout_run.reload.status).to eq('completed')

    expect { described_class.new.call(transfer) }.not_to change { transfer.reload.attempts }
  end

  it 'a rejected destination holds the statement' do
    transfer = transfer_for(account_last_four: '0000')
    described_class.new.call(transfer)
    expect(transfer.reload.state).to eq('rejected')
    expect(transfer.statement.reload).to have_attributes(status: 'held', hold_reason: 'transfer_rejected')
    expect(transfer.statement.payout_run.reload.status).to eq('completed')
    expect { described_class.new.call(transfer) }.not_to change { transfer.reload.attempts }
  end

  it 'leaves the run open while another statement is still finalized' do
    second = Author.create!(name: 'Second', email: "second-#{SecureRandom.hex(3)}@example.test")
    second.memberships.create!(organization: @organization, role: 'author')
    other_payee = individual_payee(second)
    other_article = Article.create!(author: second, publication: @publication, title: 'Other', body: 'Some words')
    transfer = transfer_for
    Payouts::AccrueEarning.new.call(payee: other_payee, source: other_article, kind: :article_fee, amount_cents: 4000,
      earned_on: Date.current, description: 'Other')
    run = transfer.statement.payout_run
    other_statement = run.statements.create!(payee: other_payee, status: 'finalized', total_cents: 4000, currency: 'USD')
    described_class.new.call(transfer)
    expect(run.reload.status).to eq('finalized')
    expect(other_statement.reload.status).to eq('finalized')
  end
end
