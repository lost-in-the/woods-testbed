require 'rails_helper'

RSpec.describe Payouts::SubmitTransferJob do
  include ActiveJob::TestHelper

  before do
    setup_canopy
    rate_card(basis: 'flat', flat_cents: 5000)
    individual_payee(simulate_timeout: '1')
    publish_article
  end

  def finalize
    run = Payouts::StartPayoutRun.new(author: @editor).call(organization: @organization, period_start: Date.current.beginning_of_month)
    Payouts::FinalizePayoutRun.new(author: @editor).call(run).statements.first.transfer
  end

  it 'the job retries transient errors' do
    transfer = nil
    perform_enqueued_jobs(only: described_class) { transfer = finalize }
    expect(transfer.reload).to have_attributes(state: 'settled', attempts: 2)
  end

  it 'discards a missing transfer' do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  it 'reconcile re-enqueues failed transfers only' do
    transfer = finalize
    expect { Payouts::SubmitTransfer.new.call(transfer) }.to raise_error(Payouts::FakeLedgerClient::TransientError)
    expect { Payouts::ReconcileTransfersJob.perform_now }.to have_enqueued_job(described_class).with(transfer.id).once
  end

  it 'the monthly job starts last month for each organization through its editor' do
    first_of_next = Date.current.next_month.beginning_of_month
    travel_to(first_of_next.in_time_zone + 6.hours) do
      expect { Payouts::MonthlyPayoutRunJob.perform_now }.to change { @organization.payout_runs.count }.by(1)
      run = @organization.payout_runs.last
      expect(run).to have_attributes(period_start: first_of_next.prev_month, organization: @organization, started_by: @editor)
      expect { Payouts::MonthlyPayoutRunJob.perform_now }.not_to change { @organization.payout_runs.count }
    end
  end
end
