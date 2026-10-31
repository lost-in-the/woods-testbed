require 'rails_helper'

RSpec.describe 'Syndication pages', type: :request do
  before do
    setup_canopy
    publish_article
    @partner = partner
  end

  it 'renders the partner index and show pages for an editor' do
    license_for(@article, @partner)
    login
    [syndication_partners_path, syndication_partner_path(@partner)].each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path}: #{response.status} #{response.body.first(200)}"
    end
    expect(response.body).to include(@article.title)
  end

  it 'refuses authors' do
    login(@writer)
    get syndication_partners_path
    expect(response).to have_http_status(:forbidden)
    get syndication_partner_path(@partner)
    expect(response).to have_http_status(:forbidden)
  end

  it 'returns 404 for another organization\'s partner' do
    other = Organization.create!(name: 'Other Press', slug: "other-#{SecureRandom.hex(4)}")
    login
    get syndication_partner_path(partner(other, name: 'Elsewhere'))
    expect(response).to have_http_status(:not_found)
  end

  it 'creates a partner' do
    login
    expect { post syndication_partners_path, params: { name: 'Hill Gazette', contact_email: 'Desk@Hill.test' } }.to change(Syndication::Partner, :count).by(1)
    created = Syndication::Partner.order(:id).last
    expect(response).to redirect_to(syndication_partner_path(created))
    expect(created.contact_email).to eq('desk@hill.test')
  end

  it 'grants and revokes a license from the partner page' do
    login
    expect {
      post syndication_licenses_path, params: { partner_id: @partner.id, article_id: @article.id, territory: 'US',
        starts_on: Date.current.to_s, ends_on: (Date.current + 30).to_s, fee_cents: 10_000 }
    }.to change(Syndication::License, :count).by(1)
    expect(response).to redirect_to(syndication_partner_path(@partner))
    license = Syndication::License.last
    post revoke_syndication_license_path(license)
    expect(response).to redirect_to(syndication_partner_path(@partner))
    expect(Syndication::License.unscoped.find(license.id)).to be_revoked
    get syndication_partner_path(@partner)
    expect(response).to have_http_status(:ok)
  end

  it 'returns 404 when revoking a license that is not in this organization' do
    login
    post revoke_syndication_license_path(id: 0)
    expect(response).to have_http_status(:not_found)
  end
end
