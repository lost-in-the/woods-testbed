module Newsletter
  class CampaignsController < ApplicationController
    before_action :require_session
    before_action :require_editor
    def index
      @campaigns = scope.order(id: :desc).limit(25).offset(page_offset)
      @articles = Article.joins(:publication).where(publications: { organization_id: current_organization.id }).published.not_archived.order(id: :desc).limit(100)
    end
    def show
      @campaign = scope.find(params[:id])
      @deliveries = @campaign.deliveries.includes(:subscriber).limit(25).offset(page_offset)
    end
    def create
      article = Article.joins(:publication).where(publications: { organization_id: current_organization.id }).find(params[:article_id])
      campaign = Campaign.create!(article: article, publication: article.publication, subject: params.require(:subject))
      redirect_to newsletter_campaign_path(campaign)
    end
    def send_campaign
      campaign = scope.find(params[:id])
      SendCampaign.new.call(campaign: campaign, author: current_author)
      redirect_to newsletter_campaign_path(campaign)
    end
    def drain
      campaign = scope.find(params[:id])
      campaign.deliveries.where(state: 'queued').find_each { |delivery| DeliverJob.perform_now(delivery.id) }
      redirect_to newsletter_campaign_path(campaign)
    end
    def engage
      campaign = scope.find(params[:id])
      delivery = campaign.deliveries.where(state: 'delivered').find(params.require(:delivery_id))
      delivery.engagement_events.create!(subscriber: delivery.subscriber, article: campaign.article, kind: params.require(:kind), metadata: { source: 'demo', device: { kind: 'browser' } })
      redirect_to newsletter_campaign_path(campaign)
    end
    private
    def scope = Campaign.joins(:publication).where(publications: { organization_id: current_organization.id })
  end
end
