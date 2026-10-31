require 'rails_helper'

RSpec.describe 'Payouts models' do
  include ActiveJob::TestHelper
  before { setup_canopy }

  it 'pays an agency for the authors it represents' do
    agency = agency_payee(@writer)
    expect(Payouts::Payee.for_author(@writer, @organization)).to eq(agency)
    expect(Payouts::Payee.for_author(@editor, @organization)).to be_nil
  end

  it 'refuses an individual payee for an agency-represented author' do
    agency_payee(@writer)
    expect { individual_payee(@writer) }.to raise_error(ActiveRecord::RecordInvalid, /represented by an agency/)
  end

  it 'refuses representing an author who is already paid directly' do
    individual_payee(@writer)
    expect { agency_payee(@writer) }.to raise_error(ActiveRecord::RecordInvalid, /already paid directly/)
  end

  it 'stores tax IDs encrypted, normalized, and still searchable' do
    profile = individual_payee.profile
    raw = Payouts::IndividualProfile.connection.select_value("SELECT tax_id FROM payouts_individual_profiles WHERE id = #{profile.id}")
    expect(raw).not_to include('123456789')
    expect(profile.reload.tax_id).to eq('123456789')
    expect(Payouts::IndividualProfile.find_by(tax_id: '123-45-6789')).to eq(profile)
    expect(profile.account_last_four).to eq('4321')
  end

  it 'refuses nested representations before the agency has a payee' do
    expect {
      Payouts::AgencyProfile.create!(name: 'Early Agency', contact_email: 'desk@early.test', representations_attributes: [{ author_id: @writer.id }])
    }.to raise_error(ActiveRecord::RecordInvalid, /payee/)
  end

  it 'normalizes agency contact email' do
    profile = Payouts::AgencyProfile.create!(name: 'Desk', contact_email: ' Desk@Agency.TEST ')
    expect(profile.contact_email).to eq('desk@agency.test')
  end

  it 'picks the newest effective rate card' do
    rate_card(effective_on: Date.new(2026, 1, 1), cents_per_word: 3)
    newest = rate_card(effective_on: Date.new(2026, 6, 1), cents_per_word: 5)
    rate_card(effective_on: Date.new(2027, 1, 1), cents_per_word: 9)
    expect(Payouts::RateCard.current_for(@publication, on: Date.new(2026, 9, 14))).to eq(newest)
    expect(newest.cents_per_word).to eq(5)
  end

  it 'models international bank transfers as an STI grandchild' do
    expect(Payouts::InternationalBankTransfer.superclass).to eq(Payouts::BankTransfer)
    expect(Payouts::BankTransfer.superclass).to eq(Payouts::Transfer)
    expect(Payouts::Transfer.class_for('international_bank')).to eq(Payouts::InternationalBankTransfer)
    expect(Payouts::InternationalBankTransfer.new(amount_cents: 1, idempotency_key: 'k')).to have_attributes(valid?: false)
  end

  it 'enqueues submission once, after the transfer commits' do
    run = Payouts::PayoutRun.create!(organization: @organization, period_start: Date.new(2026, 8, 1), started_by: @editor)
    statement = run.statements.create!(payee: individual_payee, total_cents: 3000)
    transfer = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      transfer = Payouts::BankTransfer.create!(statement: statement, amount_cents: 3000, idempotency_key: "statement-#{statement.id}", account_last_four: '4321')
      expect(Payouts::SubmitTransferJob).not_to have_been_enqueued
    end
    expect(Payouts::SubmitTransferJob).to have_been_enqueued.with(transfer.id).exactly(:once)
    expect(transfer).to be_pending
  end

  it 'keeps statements inside one organization' do
    other = Organization.create!(name: 'Other', slug: "other-#{SecureRandom.hex(3)}")
    run = Payouts::PayoutRun.create!(organization: other, period_start: Date.new(2026, 8, 1), started_by: @editor)
    expect(run.statements.new(payee: individual_payee)).not_to be_valid
  end

  it 'requires payout runs to start on the first of a month' do
    expect(Payouts::PayoutRun.new(organization: @organization, period_start: Date.new(2026, 8, 2), started_by: @editor)).not_to be_valid
  end
end
