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

  it 'completes an empty run without transfers or notifications and is idempotent' do
    run = run_for
    expect(run.statements).to be_empty
    expect { finalize(run) }.not_to change { [Payouts::Transfer.count, ActiveJob::Base.queue_adapter.enqueued_jobs.size] }
    expect(run.reload.status).to eq('completed')
    expect(run.finalized_at).to be_present

    travel 1.minute do
      expect { finalize(run) }.not_to change {
        [run.reload.status, run.finalized_at, run.updated_at, Payouts::Transfer.count, ActiveJob::Base.queue_adapter.enqueued_jobs.size]
      }
    end
  end

  it 'completes an all-held run and preserves earnings for the next period' do
    payee = individual_payee
    rate_card(basis: 'flat', flat_cents: 1000, effective_on: Date.new(2026, 2, 1))
    publish_article
    run = run_for
    statement = run.statements.sole
    earning = Payouts::Earning.where(payee: payee).sole

    expect { finalize(run) }.not_to change { [Payouts::Transfer.count, ActiveJob::Base.queue_adapter.enqueued_jobs.size] }
    expect(run.reload.status).to eq('completed')
    expect(run.finalized_at).to be_present
    expect(statement.reload).to have_attributes(status: 'held', hold_reason: 'below_minimum', total_cents: 1000)
    expect(earning.reload.statement_id).to be_nil

    travel 1.minute do
      expect { finalize(run) }.not_to change {
        [run.reload.status, run.finalized_at, run.updated_at, Payouts::Transfer.count, ActiveJob::Base.queue_adapter.enqueued_jobs.size]
      }
    end

    other = Article.create!(author: @writer, publication: @publication, title: 'Next month', body: 'More words')
    Payouts::AccrueEarning.new.call(payee: payee, source: other, kind: :article_fee, amount_cents: 2000,
      earned_on: run.period_start.next_month, description: 'Next fee')
    next_statement = run_for(run.period_start.next_month).statements.sole
    expect(next_statement).to have_attributes(status: 'draft', total_cents: 3000)
    expect(earning.reload.statement_id).to eq(next_statement.id)
  end

  it 'keeps a mixed run finalized until its payable statement settles' do
    individual_payee
    publish_article
    second = Author.create!(name: 'Held Writer', email: "held-#{SecureRandom.hex(4)}@example.test")
    second.memberships.create!(organization: @organization, role: 'author')
    held_payee = individual_payee(second)
    earning = Payouts::AccrueEarning.new.call(payee: held_payee, source: @article, kind: :article_fee,
      amount_cents: 1000, earned_on: Date.current, description: 'Co-author fee')
    run = run_for

    expect { finalize(run) }.to change(Payouts::Transfer, :count).by(1)
      .and have_enqueued_job(Payouts::SubmitTransferJob).once
      .and have_enqueued_mail(ContributorMailer, :statement_ready).once
    expect(run.reload.status).to eq('finalized')
    expect(run.finalized_at).to be_present
    held = run.statements.held.sole
    payable = run.statements.finalized.sole
    expect(held).to have_attributes(payee: held_payee, hold_reason: 'below_minimum')

    Payouts::SubmitTransfer.new.call(payable.transfer)
    expect(run.reload.status).to eq('completed')
    expect(payable.reload.status).to eq('paid')
    expect(held.reload.status).to eq('held')
    expect(earning.reload.statement_id).to be_nil
  end

  it 'an author cannot finalize a run' do
    individual_payee
    publish_article
    run = run_for
    expect { described_class.new(author: @writer).call(run) }.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'enqueues statement mail only after the whole run finalizes' do
    individual_payee
    publish_article
    second = Author.create!(name: 'Second Writer', email: "second-#{SecureRandom.hex(4)}@example.test")
    second.memberships.create!(organization: @organization, role: 'author')
    Payouts::AccrueEarning.new.call(payee: individual_payee(second), source: @article, kind: :article_fee,
      amount_cents: 5000, earned_on: Date.current, description: 'Co-author fee')
    run = run_for
    calls = 0
    allow(Payouts::BankTransfer).to receive(:create!).and_wrap_original do |original, **attributes|
      calls += 1
      raise ActiveRecord::RecordInvalid, Payouts::BankTransfer.new if calls == 2
      original.call(**attributes)
    end
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    expect { finalize(run) }.to raise_error(ActiveRecord::RecordInvalid)
    added = ActiveJob::Base.queue_adapter.enqueued_jobs.drop(jobs_before).map { |job| job[:job] }
    expect(added).not_to include(ActionMailer::MailDeliveryJob)
    expect(run.reload).to be_drafted
    expect(run.statements.pluck(:status).uniq).to eq(['draft'])
  end
end
