require 'rails_helper'
RSpec.describe 'Canopy pages', type: :request do
  before { setup_canopy }
  it 'provides a demo entry and authenticated navigation' do
    get root_path
    expect(response).to redirect_to(demo_session_path)
    get demo_session_path
    expect(response).to have_http_status(:ok)
    login
    [root_path, articles_path, new_article_path, article_path(@article), edit_article_path(@article), article_comments_path(@article), subscribers_path, subscriber_path(@subscriber), billing_invoices_path, billing_invoice_path(invoice), newsletter_campaigns_path, support_tickets_path].each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path}: #{response.status} #{response.body.first(200)}"
    end
  end
  it 'creates a draft through a form and then completes review and publishing' do
    login(@writer)
    post articles_path, params: { article: { publication_id: @publication.id, title: 'A new path', body: 'Access report' } }
    expect(response).to have_http_status(:redirect)
    article = Article.find_by!(title: 'A new path')
    post submit_article_path(article), params: { reviewer_id: @editor.id }
    expect(article.reload.state).to eq('in_review')
    login
    post decide_article_path(article), params: { assignment_id: article.latest_revision.review_assignments.first.id, outcome: 'approved' }
    post publish_article_path(article)
    expect(article.reload.state).to eq('published')
    delete demo_session_path
    get read_article_path(article.slug)
    expect(response).to have_http_status(:ok)
  end
  it 'enforces author permissions on billing and review actions' do
    login(@writer)
    get billing_invoices_path
    expect(response).to have_http_status(:forbidden)
    post publish_article_path(@article)
    expect(response).to have_http_status(:forbidden)
  end
  it 'does not allow selecting an organization outside the signed-in memberships' do
    login
    other = Organization.create!(name: 'Other', slug: 'outside')
    patch demo_session_path, params: { organization_id: other.id }
    expect(response).to have_http_status(:not_found)
  end
  it 'does not reveal another organization article by ID' do
    other = Organization.create!(name: 'Other', slug: 'other')
    @writer.memberships.delete_all
    @writer.memberships.create!(organization: other, role: 'author')
    login(@writer)
    get article_path(@article)
    expect(response).to have_http_status(:not_found)
  end
  it 'uses the same publishing rules through GraphQL' do
    login
    post graphql_path, params: { query: "mutation { publishArticle(id: \"#{@article.id}\") { errors article { id } } }" }
    expect(response.parsed_body.dig('data', 'publishArticle', 'errors')).not_to be_empty
    approve_article
    post graphql_path, params: { query: "mutation { publishArticle(id: \"#{@article.id}\") { errors article { id } } }" }
    expect(response.parsed_body.dig('data', 'publishArticle', 'errors')).to eq([])
    expect(@article.reload.state).to eq('published')
  end
  it 'renders newsletter, invoice and ticket detail flows' do
    publish_article
    invoice
    campaign = @publication.campaigns.create!(article: @article, subject: 'Dispatch')
    ticket = @subscriber.tickets.create!(title: 'Help', subject: invoice)
    login
    [newsletter_campaign_path(campaign), support_ticket_path(ticket)].each do |path|
      get path
      expect(response).to have_http_status(:ok)
    end
    post pay_billing_invoice_path(invoice), params: { key: 'request-payment' }
    expect(invoice.reload.settled_at).not_to be_nil
    patch support_ticket_path(ticket), params: { body: 'Resolved your renewal.', resolve: '1' }
    expect(ticket.reload.state).to eq('resolved')
  end
  it 'organizes a story into a collection with order and tags' do
    login
    post collections_path, params: { publication_id: @publication.id, name: 'Reading list' }
    collection = @publication.collections.find_by!(name: 'Reading list')
    patch collection_path(collection), params: { article_id: @article.id, position: 3, tag: 'Fieldwork' }
    expect(collection.collection_articles.first!.position).to eq(3)
    expect(@article.tags.pluck(:name)).to eq(['fieldwork'])
    get collection_path(collection)
    expect(response).to have_http_status(:ok)
    login(@writer)
    patch collection_path(collection), params: { article_id: @article.id, position: 1 }
    expect(response).to have_http_status(:forbidden)
  end

  it 'records a simulated click only for a delivered newsletter' do
    publish_article
    invoice
    campaign = @publication.campaigns.create!(article: @article, subject: 'Click test')
    delivery = campaign.deliveries.create!(subscriber: @subscriber)
    login
    post engage_newsletter_campaign_path(campaign), params: { delivery_id: delivery.id, kind: 'click' }
    expect(response).to have_http_status(:not_found)
    Newsletter::DeliverJob.perform_now(delivery.id)
    post engage_newsletter_campaign_path(campaign), params: { delivery_id: delivery.id, kind: 'click' }
    expect(delivery.engagement_events.first!.kind).to eq('click')
  end

end
