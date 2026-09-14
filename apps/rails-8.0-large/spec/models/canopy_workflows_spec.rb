require 'rails_helper'

RSpec.describe 'Canopy business workflows' do
  before { setup_canopy }
  it 'publishes a reviewed revision once and records its event' do
    approve_article
    service = PublishArticle.new(author: @editor)
    expect(PublishArticleJob).to receive(:perform_later).with(@article.id).once
    expect { 2.times { service.call(@article) } }.to change(ActivityEvent, :count).by(1)
    expect(@article.reload.state).to eq('published')
  end
  it 'refuses publishing an unapproved draft' do
    expect { PublishArticle.new(author: @editor).call(@article) }.to raise_error(EditorialWorkflow::InvalidTransition)
  end
  it 'rejects approval for an older revision after edits' do
    @workflow.submit(@article, reviewer: @editor)
    old_assignment = @article.latest_revision.review_assignments.first!
    @workflow.save_draft(@article, title: 'New title', body: 'Changed facts')
    expect { @review.decide(old_assignment, outcome: 'approved') }.to raise_error(EditorialWorkflow::InvalidTransition)
    expect(old_assignment.reload.review_decision).to be_nil
  end
  it 'resets approval when approved content changes' do
    approve_article
    @workflow.save_draft(@article, body: 'Updated report')
    expect(@article.state).to eq('draft')
    expect { PublishArticle.new(author: @editor).call(@article) }.to raise_error(EditorialWorkflow::InvalidTransition)
  end
  it 'preserves immutable revision content' do
    expect { @article.latest_revision.update!(body: 'Rewrite history') }.to raise_error(ActiveRecord::RecordInvalid)
  end
  it 'requires an editor for review and publication' do
    expect { @workflow.submit(@article, reviewer: @writer) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { PublishArticle.new(author: @writer).call(@article) }.to raise_error(Pundit::NotAuthorizedError)
  end
  it 'publishes scheduled content only after it becomes due' do
    approve_article
    @review.schedule(@article, at: Time.current + 1.day)
    expect { PublishArticle.new(author: @editor).call(@article) }.to raise_error(EditorialWorkflow::InvalidTransition)
    travel 2.days do
      PublishDueArticlesJob.perform_now
      expect(@article.reload.state).to eq('published')
    end
  end
  it 'rejects cross-organization associations' do
    other = Organization.create!(name: 'Other', slug: 'other')
    @subscriber.update!(organization: other)
    expect { @billing.activate(subscriber: @subscriber, plan: @plan) }.to raise_error(Pundit::NotAuthorizedError)
    expect(Billing::Subscription.new(subscriber: @subscriber, plan: @plan, renews_at: Time.current)).not_to be_valid
  end
  it 'prevents comment cycles and cross-article parents' do
    a = @article.comments.create!(body: 'First')
    b = @article.comments.create!(body: 'Reply', parent: a)
    expect { a.update!(parent: b) }.to raise_error(ActiveRecord::RecordInvalid)
    other = Article.create!(author: @writer, publication: @publication, title: 'Other story')
    expect(other.comments.new(body: 'Wrong thread', parent: b)).not_to be_valid
  end
  it 'creates one invoice for repeated subscription activation' do
    expect { 2.times { @billing.activate(subscriber: @subscriber, plan: @plan) } }.to change(Billing::Invoice, :count).by(1)
  end
  it 'preserves the invoice price when the plan price changes' do
    original = invoice
    @plan.update!(amount_cents: 9900)
    expect(original.total_cents).to eq(1200)
  end
  it 'does not duplicate a payment when a job retries' do
    invoice_id = invoice.id
    expect { 2.times { Billing::ChargePaymentJob.perform_now(invoice_id) } }.to change(Billing::Payment, :count).by(1)
    expect(invoice.reload.settled_at).not_to be_nil
  end
  it 'retains a failed attempt and allows a separate successful attempt' do
    service = Billing::CollectPayment.new
    declined = service.call(invoice: invoice, key: 'decline', outcome: 'failure')
    expect(service.call(invoice: invoice, key: 'decline').state).to eq('failed')
    service.call(invoice: invoice, key: 'retry')
    expect(declined.reload.state).to eq('failed')
    expect(invoice.payments.pluck(:state)).to contain_exactly('failed', 'captured')
  end
  it 'enforces refund balance and idempotency' do
    payment = Billing::CollectPayment.new.call(invoice: invoice, key: 'paid')
    service = Billing::RefundPayment.new
    2.times { service.call(payment: payment, amount_cents: 300, key: 'refund', reason: 'Credit') }
    expect(payment.refunds.sum(:amount_cents)).to eq(300)
    expect { service.call(payment: payment, amount_cents: 901, key: 'too-much', reason: 'Credit') }.to raise_error(ActiveRecord::RecordInvalid)
  end
  it 'never refunds a declined payment' do
    payment = Billing::CollectPayment.new.call(invoice: invoice, key: 'declined', outcome: 'failure')
    expect { Billing::RefundPayment.new.call(payment: payment, amount_cents: 100, key: 'no', reason: 'Credit') }.to raise_error(ActiveRecord::RecordInvalid)
  end
  it 'renews once at a fixed due date and skips canceled subscriptions' do
    subscription = @billing.activate(subscriber: @subscriber, plan: @plan)
    at = subscription.renews_at
    expect { 2.times { @billing.renew(subscription, at: at) } }.to change(Billing::Invoice, :count).by(1)
    @billing.cancel(subscription)
    expect { @billing.renew(subscription, at: at + 60.days) }.not_to change(Billing::Invoice, :count)
  end
  it 'sends one newsletter delivery per eligible reader and drains idempotently' do
    publish_article
    @billing.activate(subscriber: @subscriber, plan: @plan)
    @subscriber.update!(preferences: { simulate_bounce: true })
    campaign = @publication.campaigns.create!(article: @article, subject: 'Field dispatch')
    expect { 2.times { Newsletter::SendCampaign.new.call(campaign: campaign, author: @editor) } }.to change(Newsletter::Delivery, :count).by(1)
    delivery = campaign.deliveries.first!
    2.times { Newsletter::DeliverJob.perform_now(delivery.id) }
    expect(delivery.reload.state).to eq('bounced')
  end
  it 'honors newsletter opt-out' do
    publish_article
    @billing.activate(subscriber: @subscriber, plan: @plan)
    @subscriber.update!(preferences: { newsletter: false })
    campaign = @publication.campaigns.create!(article: @article, subject: 'Dispatch')
    expect { Newsletter::SendCampaign.new.call(campaign: campaign, author: @editor) }.not_to change(Newsletter::Delivery, :count)
  end
  it 'rejects a ticket referencing another subscriber invoice' do
    other = @organization.subscribers.create!(name: 'Other', email: 'other@example.test')
    expect(other.tickets.new(title: 'Wrong owner', subject: invoice)).not_to be_valid
  end
  it 'records one resolution and retries webhook delivery without network access' do
    endpoint = @organization.webhook_endpoints.create!(url: 'https://example.test/hook', secret: 'fictional')
    ticket = @subscriber.tickets.create!(title: 'Payment question', subject: invoice)
    expect { 2.times { Support::ResolveTicket.new.call(ticket: ticket, author: @editor) } }.to change(ActivityEvent, :count).by(1)
    delivery = endpoint.webhook_deliveries.first!
    WebhookDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload.state).to eq('failed')
    2.times { WebhookDeliveryJob.perform_now(delivery.id) }
    expect(delivery.reload.attributes.slice('state', 'attempts')).to eq('state' => 'delivered', 'attempts' => 2)
  end
  it 'maintains the article comment counter through create and destroy' do
    comment = @article.comments.create!(body: 'Counter check')
    expect(@article.reload.comments_count).to eq(1)
    comment.destroy!
    expect(@article.reload.comments_count).to eq(0)
  end

end
