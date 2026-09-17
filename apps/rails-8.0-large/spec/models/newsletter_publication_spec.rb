require 'rails_helper'

RSpec.describe 'Newsletter publication isolation' do
  before do
    setup_canopy
    publish_article
    @campaign = @publication.campaigns.create!(article: @article, subject: 'Scoped dispatch')

    subscribe(@subscriber)
    subscribe(@subscriber)
    @opted_out = @organization.subscribers.create!(name: 'Opted out', email: 'out@example.test', preferences: { newsletter: false })
    subscribe(@opted_out)
    canceled = @organization.subscribers.create!(name: 'Canceled', email: 'canceled@example.test')
    subscribe(canceled, state: 'canceled')
    @organization.subscribers.create!(name: 'No subscription', email: 'none@example.test')

    sibling = @organization.publications.create!(name: 'Sibling', slug: 'sibling')
    sibling_reader = @organization.subscribers.create!(name: 'Sibling reader', email: 'sibling@example.test')
    subscribe(sibling_reader, publication: sibling)
  end

  def subscribe(subscriber, publication: @publication, state: 'active')
    plan = publication.plans.create!(name: "Plan #{SecureRandom.hex(3)}", amount_cents: 700)
    Billing::Subscription.create!(subscriber: subscriber, plan: plan, state: state, renews_at: 30.days.from_now)
  end

  it 'selects each active reader of this publication once, leaving opt-out to sending' do
    foreign = Organization.create!(name: 'Foreign', slug: 'foreign')
    foreign_publication = foreign.publications.create!(name: 'Foreign notes', slug: 'foreign-notes')
    foreign_reader = foreign.subscribers.create!(name: 'Foreign reader', email: 'foreign@example.test')
    subscribe(foreign_reader, publication: foreign_publication)

    expect(@campaign.recipients).to be_a(ActiveRecord::Relation)
    expect(@campaign.recipients.pluck(:id)).to contain_exactly(@subscriber.id, @opted_out.id)
  end

  it 'sends only to eligible readers of this publication and remains idempotent' do
    expect do
      2.times { Newsletter::SendCampaign.new.call(campaign: @campaign, author: @editor) }
    end.to change(Newsletter::Delivery, :count).by(1)
    expect(@campaign.deliveries.pluck(:subscriber_id)).to eq([@subscriber.id])
    expect(@campaign.reload.state).to eq('sent')
  end

  it 'requires editor permission before sending' do
    expect do
      Newsletter::SendCampaign.new.call(campaign: @campaign, author: @writer)
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(@campaign.reload.state).to eq('draft')
    expect(@campaign.deliveries.count).to eq(0)
  end
end
