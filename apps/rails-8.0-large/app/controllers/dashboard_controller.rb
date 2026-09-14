class DashboardController < ApplicationController
  before_action :require_session
  def index
    @report = EditorialReport.new(current_organization)
    @events = current_organization.activity_events.order(id: :desc).limit(15)
    @webhooks = WebhookDelivery.joins(:webhook_endpoint).where(webhook_endpoints: { organization_id: current_organization.id }).order(id: :desc).limit(15)
  end
  def run_due
    require_editor
    current_organization.publications.each do |publication|
      publication.articles.where(state: 'scheduled').where('scheduled_at <= ?', Time.current).find_each { |article| PublishArticle.new(author: current_author).call(article) }
    end
    Billing::Subscription.joins(:subscriber).where(subscribers: { organization_id: current_organization.id }).active.where('renews_at <= ?', Time.current).find_each do |subscription|
      Billing::SubscriptionWorkflow.new(author: current_author).renew(subscription)
    end
    redirect_to root_path, notice: 'Due publishing and renewals completed.'
  end
  def retry_webhook
    require_editor
    delivery = WebhookDelivery.joins(:webhook_endpoint).where(webhook_endpoints: { organization_id: current_organization.id }).find(params[:id])
    WebhookDeliveryJob.perform_now(delivery.id)
    redirect_to root_path
  end
end
