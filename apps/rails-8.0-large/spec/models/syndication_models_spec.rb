require 'rails_helper'

RSpec.describe 'Syndication models' do
  before do
    setup_canopy
    publish_article
    @partner = partner
  end

  it 'only licenses published articles' do
    draft = Article.new(author: @writer, publication: @publication)
    @workflow.save_draft(draft, title: 'Unpublished', body: 'Draft')
    expect { license_for(draft, @partner) }.to raise_error(ActiveRecord::RecordInvalid, /published/)
  end

  it 'refuses overlapping exclusive licenses in the same territory' do
    license_for(@article, @partner, exclusive: true)
    expect { license_for(@article, partner(name: 'Hill Times'), exclusive: true) }.to raise_error(ActiveRecord::RecordInvalid, /exclusive/)
  end

  it 'treats a worldwide exclusive license as covering every territory' do
    license_for(@article, @partner, territory: 'worldwide', exclusive: true)
    expect { license_for(@article, partner(name: 'Hill Times'), territory: 'US') }.to raise_error(ActiveRecord::RecordInvalid, /exclusive/)
  end

  it 'allows exclusive licenses in windows that do not overlap' do
    license_for(@article, @partner, exclusive: true, ends_on: Date.current + 10)
    expect(license_for(@article, partner(name: 'Hill Times'), exclusive: true, starts_on: Date.current + 11, ends_on: Date.current + 20)).to be_persisted
  end

  it 'hides revoked licenses from the default scope' do
    license = license_for(@article, @partner)
    license.update!(revoked_at: Time.current)
    expect(Syndication::License.all).not_to include(license)
    expect(Syndication::License.unscoped.find(license.id)).to eq(license)
  end

  it 'defaults the granting editor to the current author' do
    Current.set(author: @editor) do
      license = Syndication::License.create!(partner: @partner, article: @article, territory: 'CA', starts_on: Date.current, ends_on: Date.current + 5, fee_cents: 500)
      expect(license.granted_by).to eq(@editor)
    end
  end

  it 'refuses a partner from another organization' do
    other = Organization.create!(name: 'Other', slug: "other-#{SecureRandom.hex(3)}")
    expect { license_for(@article, partner(other, name: 'Far Gazette')) }.to raise_error(ActiveRecord::RecordInvalid, /organization/)
  end

  it 'generates a partner API token' do
    expect(@partner.api_token).to be_present
  end
end
