require 'rails_helper'
RSpec.describe 'Partner API', type: :request do
  before do
    setup_canopy
    publish_article
    @partner = partner
    @license = license_for(@article, @partner)
  end
  let(:headers) { { 'Authorization' => "Token token=#{@partner.api_token}" } }

  it 'v1 lists only the partner\'s active licenses' do
    expired = Article.new(author: @writer, publication: @publication)
    @workflow.save_draft(expired, title: 'Old story', body: 'Old')
    @workflow.submit(expired, reviewer: @editor)
    @review.decide(expired.latest_revision.review_assignments.first!, outcome: 'approved')
    PublishArticle.new(author: @editor).call(expired)
    license_for(expired, @partner, starts_on: Date.current - 60, ends_on: Date.current - 30)
    license_for(@article, partner(name: 'Other Courier'), territory: 'CA')
    get '/api/v1/licenses', headers: headers
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body['licenses'].map { |l| l['id'] }).to eq([@license.id])
    expect(body['licenses'].first).to eq(
      'id' => @license.id, 'territory' => 'US', 'starts_on' => @license.starts_on.iso8601, 'ends_on' => @license.ends_on.iso8601,
      'exclusive' => false, 'article' => { 'title' => @article.title, 'slug' => @article.slug, 'body' => @article.body }
    )
    get "/api/v1/licenses/#{@license.id}", headers: headers
    expect(response.parsed_body['license']['id']).to eq(@license.id)
  end

  it 'v2 wraps data and includes usage' do
    @license.usage_reports.create!(period_start: Date.new(2026, 10, 1), pickups: 4, impressions: 40, reported_at: Time.current)
    get '/api/v2/licenses', headers: headers
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body['meta']).to eq('count' => 1)
    entry = body['data'].first
    expect(entry).to include('id' => @license.id, 'territory' => 'US', 'article' => include('slug' => @article.slug))
    expect(entry['usage']).to contain_exactly(include('period_start' => '2026-10-01', 'pickups' => 4, 'impressions' => 40))
    get "/api/v2/licenses/#{@license.id}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'missing or suspended tokens get 401' do
    get '/api/v1/licenses'
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq('error' => 'unauthorized')
    get '/api/v1/licenses', headers: { 'Authorization' => 'Token token=nope' }
    expect(response).to have_http_status(:unauthorized)
    @partner.suspended!
    get '/api/v2/licenses', headers: headers
    expect(response).to have_http_status(:unauthorized)
    post '/api/v2/usage_reports', params: { reports: [] }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'another partner\'s license id gets 404' do
    other = license_for(@article, partner(name: 'Other Courier'), territory: 'CA')
    [1, 2].each do |v|
      get "/api/v#{v}/licenses/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq('error' => 'not_found')
    end
  end

  it 'a revoked license id gets 404' do
    Syndication::RevokeLicense.new(author: @editor).call(@license)
    get "/api/v1/licenses/#{@license.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    get '/api/v2/licenses', headers: headers
    expect(response.parsed_body['data']).to eq([])
  end

  it 'v2 usage post returns 202 and enqueues the import' do
    reports = [{ license_id: @license.id, period_start: '2026-10-01', pickups: 2, impressions: 9 }]
    expect {
      post '/api/v2/usage_reports', params: { reports: reports }, headers: headers, as: :json
    }.to have_enqueued_job(Syndication::ImportUsageReportJob).with(@partner.id, anything)
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq('accepted' => 1)
    perform_enqueued_jobs { post '/api/v2/usage_reports', params: { reports: reports }, headers: headers, as: :json }
    expect(Syndication::UsageReport.last).to have_attributes(license_id: @license.id, pickups: 2)
  end

  it 'assigns the partner organization as the current tenant inside an action' do
    seen = nil
    allow_any_instance_of(Api::V1::LicensesController).to receive(:index).and_wrap_original do |original, *args|
      seen = [Current.organization, Current.partner, Current.author]
      original.call(*args)
    end
    get '/api/v1/licenses', headers: headers
    expect(seen).to eq([@organization, @partner, nil])
  end
end
