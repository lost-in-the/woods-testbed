require 'rails_helper'

RSpec.describe 'Payout pages', type: :request do
  before do
    setup_canopy
    rate_card(basis: 'flat', flat_cents: 5000)
    @payee = individual_payee
    publish_article
    @run = Payouts::StartPayoutRun.new(author: @editor).call(organization: @organization, period_start: Date.current.beginning_of_month)
    @statement = @run.statements.first!
  end

  def other_organization_statement
    other = Organization.create!(name: 'Other Press', slug: "other-#{SecureRandom.hex(4)}")
    boss = Author.create!(name: 'Boss', email: "boss-#{SecureRandom.hex(4)}@example.test")
    boss.memberships.create!(organization: other, role: 'editor')
    run = Payouts::PayoutRun.create!(organization: other, period_start: Date.current.beginning_of_month, started_by: boss)
    payee = individual_payee(boss, organization: other)
    Payouts::Statement.create!(payout_run: run, payee: payee, total_cents: 900, status: :draft)
  end

  it 'renders every index and show page for an editor' do
    login
    [payouts_payees_path, payouts_payee_path(@payee), payouts_payout_runs_path, payouts_payout_run_path(@run), payouts_statement_path(@statement)].each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path}: #{response.status} #{response.body.first(200)}"
    end
    expect(response.body).to include('$50.00 USD')
  end

  it 'refuses authors on payees and payout runs' do
    login(@writer)
    [payouts_payees_path, payouts_payee_path(@payee), payouts_payout_runs_path, payouts_payout_run_path(@run)].each do |path|
      get path
      expect(response).to have_http_status(:forbidden), path
    end
    post payouts_payout_runs_path, params: { period_start: '2026-01-01' }
    expect(response).to have_http_status(:forbidden)
  end

  it 'lets an author see their own statement but not another payee\'s' do
    login(@writer)
    get payouts_statement_path(@statement)
    expect(response).to have_http_status(:ok)
    other_writer = Author.create!(name: 'Other Writer', email: "ow-#{SecureRandom.hex(4)}@example.test")
    other_writer.memberships.create!(organization: @organization, role: 'author')
    other_statement = Payouts::Statement.create!(payout_run: @run, payee: individual_payee(other_writer), total_cents: 700)
    get payouts_statement_path(other_statement)
    expect(response).to have_http_status(:forbidden)
  end

  it 'shows a statement to an author an agency represents' do
    represented = Author.create!(name: 'Represented', email: "rp-#{SecureRandom.hex(4)}@example.test")
    represented.memberships.create!(organization: @organization, role: 'author')
    agency = agency_payee(represented)
    other_run = Payouts::PayoutRun.create!(organization: @organization, period_start: 1.month.ago.beginning_of_month.to_date, started_by: @editor)
    statement = Payouts::Statement.create!(payout_run: other_run, payee: agency, total_cents: 700)
    login(represented)
    get payouts_statement_path(statement)
    expect(response).to have_http_status(:ok)
  end

  it 'returns 404 for another organization\'s statement' do
    statement = other_organization_statement
    login
    get payouts_statement_path(statement)
    expect(response).to have_http_status(:not_found)
  end

  it 'renders the breakdown table only with preview=1' do
    login
    get payouts_statement_path(@statement)
    expect(response.body).not_to include('Breakdown by kind')
    get payouts_statement_path(@statement, preview: '1')
    expect(response.body).to include('Breakdown by kind')
    expect(response.body).to include('article_fee')
  end

  it 'renders the JSON statement through the serializer' do
    login
    get payouts_statement_path(@statement, format: :json)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(JSON.parse(Payouts::StatementSerializer.new(@statement).as_json.to_json))
    expect(response.parsed_body).to include('total_cents' => 5000, 'payee_name' => 'Writer')
  end

  it 'creates an individual payee' do
    other_writer = Author.create!(name: 'New Writer', email: "nw-#{SecureRandom.hex(4)}@example.test")
    other_writer.memberships.create!(organization: @organization, role: 'author')
    login
    expect {
      post payouts_payees_path, params: { kind: 'individual', author_id: other_writer.id, legal_name: 'New Writer', tax_id: '987-65-4321', payout_method: 'bank', account_last_four: '1111' }
    }.to change(Payouts::Payee, :count).by(1)
    payee = Payouts::Payee.order(:id).last
    expect(response).to redirect_to(payouts_payee_path(payee))
    expect(payee.profile.account_last_four).to eq('1111')
  end

  it 'creates an agency with two nested representations' do
    writers = 2.times.map do |i|
      Author.create!(name: "Rep #{i}", email: "rep-#{i}-#{SecureRandom.hex(4)}@example.test").tap { |a| a.memberships.create!(organization: @organization, role: 'author') }
    end
    login
    expect {
      post payouts_payees_path, params: { kind: 'agency', name: 'North Agency', contact_email: 'desk@north.test',
        representations_attributes: { '0' => { author_id: writers[0].id }, '1' => { author_id: writers[1].id } } }
    }.to change(Payouts::Representation, :count).by(2)
    expect(Payouts::Payee.order(:id).last.profile.authors).to match_array(writers)
  end

  it 'starts a payout run from the UI' do
    login
    expect {
      post payouts_payout_runs_path, params: { period_start: 1.month.ago.to_date.to_s }
    }.to change(Payouts::PayoutRun, :count).by(1)
    expect(response).to redirect_to(payouts_payout_run_path(Payouts::PayoutRun.order(:id).last))
  end

  it 'finalizes a run from the UI and creates transfers' do
    login
    expect { post finalize_payouts_payout_run_path(@run) }.to change(Payouts::Transfer, :count).by(1)
    expect(@run.reload).to be_finalized
    expect(response).to redirect_to(payouts_payout_run_path(@run))
  end

  describe 'GraphQL payoutStatement' do
    let(:query) { ->(id) { "{ payoutStatement(id: \"#{id}\") { id status totalCents currency payeeName holdReason } }" } }

    it 'returns the statement to an editor' do
      login
      post graphql_path, params: { query: query.call(@statement.id) }
      expect(response.parsed_body.dig('data', 'payoutStatement')).to include('totalCents' => 5000, 'payeeName' => 'Writer', 'status' => 'draft')
    end

    it 'returns an error for another organization' do
      statement = other_organization_statement
      login
      post graphql_path, params: { query: query.call(statement.id) }
      expect(response.parsed_body['errors']).not_to be_empty
      expect(response.parsed_body.dig('data', 'payoutStatement')).to be_nil
    end

    it 'returns an error to an author who is not the payee' do
      other_writer = Author.create!(name: 'Other Writer', email: "ow-#{SecureRandom.hex(4)}@example.test")
      other_writer.memberships.create!(organization: @organization, role: 'author')
      login(other_writer)
      post graphql_path, params: { query: query.call(@statement.id) }
      expect(response.parsed_body['errors']).not_to be_empty
    end
  end
end
