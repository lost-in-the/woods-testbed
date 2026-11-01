require 'rails_helper'
RSpec.describe 'Syndication workflows' do
  before do
    setup_canopy
    publish_article
    rate_card
    @partner = partner
  end
  let(:grant_params) { { partner: @partner, article: @article, territory: 'US', starts_on: Date.current, ends_on: Date.current + 30, fee_cents: 10_001 } }

  def grant(**overrides)
    Syndication::GrantLicense.new(author: @editor).call(**grant_params.merge(overrides))
  end

  it 'granting a license accrues the author\'s syndication share once' do
    payee = individual_payee
    license = nil
    expect { license = grant }.to change(Payouts::Earning, :count).by(1)
    earning = Payouts::Earning.last
    expect(earning).to have_attributes(payee: payee, source: license, kind: 'syndication_share', amount_cents: 5000)
    expect(license.granted_by).to eq(@editor)
    expect(@organization.activity_events.where(action: 'license.granted', subject: license)).to exist
    expect { Payouts::AccrueEarning.new.call(payee: payee, source: license, kind: :syndication_share, amount_cents: 5000, earned_on: Date.current, description: 'again') }
      .not_to change(Payouts::Earning, :count)
  end

  it 'granting a license for an author without a payee accrues nothing' do
    expect { grant }.not_to change(Payouts::Earning, :count)
  end

  it 'granting a license for an agency-represented author pays the agency' do
    agency = agency_payee(@writer)
    grant
    expect(Payouts::Earning.last.payee).to eq(agency)
  end

  it 'an author cannot grant a license' do
    expect { Syndication::GrantLicense.new(author: @writer).call(**grant_params) }.to raise_error(Pundit::NotAuthorizedError)
    expect(Syndication::License.count).to eq(0)
  end

  it 'a revoked license keeps its earning and leaves the API' do
    individual_payee
    license = grant
    expect { Syndication::RevokeLicense.new(author: @editor).call(license) }.not_to change(Payouts::Earning, :count)
    expect(license.reload).to be_revoked
    expect(@partner.licenses.reload).to be_empty
    expect { Syndication::RevokeLicense.new(author: @writer).call(license) }.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'usage reports upsert by license and period' do
    license = grant
    row = { license_id: license.id, period_start: Date.new(2026, 10, 1), pickups: 3, impressions: 100 }
    expect(Syndication::RecordUsage.new.call(partner: @partner, rows: [row])).to eq(1)
    expect(Syndication::RecordUsage.new.call(partner: @partner, rows: [row.merge(pickups: 9, impressions: 250)])).to eq(1)
    expect(Syndication::UsageReport.count).to eq(1)
    expect(Syndication::UsageReport.last).to have_attributes(pickups: 9, impressions: 250)
  end

  it 'usage report timestamps follow the application clock' do
    license = grant
    row = { license_id: license.id, period_start: Date.new(2026, 10, 1), pickups: 3, impressions: 100 }
    first = Time.zone.parse('2026-09-14T12:00:00Z')
    travel_to(first) { Syndication::RecordUsage.new.call(partner: @partner, rows: [row]) }
    travel_to(first + 1.day) { Syndication::RecordUsage.new.call(partner: @partner, rows: [row.merge(pickups: 4)]) }
    expect(Syndication::UsageReport.last).to have_attributes(created_at: first, updated_at: first + 1.day, reported_at: first + 1.day)
  end

  it 'usage for another partner\'s license is refused' do
    other = partner(name: 'Other Courier')
    license = grant(partner: other)
    row = { license_id: license.id, period_start: Date.new(2026, 10, 1), pickups: 1, impressions: 1 }
    expect { Syndication::RecordUsage.new.call(partner: @partner, rows: [row]) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(Syndication::UsageReport.count).to eq(0)
  end

  it 'the import job records usage for the partner' do
    license = grant
    row = { 'license_id' => license.id, 'period_start' => '2026-10-01', 'pickups' => 2, 'impressions' => 5 }
    Syndication::ImportUsageReportJob.perform_now(@partner.id, [row])
    expect(Syndication::UsageReport.last).to have_attributes(license_id: license.id, pickups: 2, impressions: 5)
  end

  it 'usage reports group any date into its month' do
    license = grant
    Syndication::RecordUsage.new.call(partner: @partner, rows: [{ license_id: license.id, period_start: '2026-10-15', pickups: 1, impressions: 1 }])
    Syndication::RecordUsage.new.call(partner: @partner, rows: [{ license_id: license.id, period_start: '2026-10-01', pickups: 2, impressions: 2 }])
    expect(Syndication::UsageReport.sole).to have_attributes(period_start: Date.new(2026, 10, 1), pickups: 2)
  end
end
