class SubscribersController < ApplicationController
  before_action :require_session
  before_action :require_editor
  def index
    @subscribers = current_organization.subscribers.order(:name).limit(25).offset(page_offset)
  end
  def show
    @subscriber = current_organization.subscribers.find(params[:id])
    @plans = Billing::Plan.joins(:publication).where(publications: { organization_id: current_organization.id })
  end
  def create
    subscriber = current_organization.subscribers.create!(params.require(:subscriber).permit(:name, :email))
    redirect_to subscriber
  end
  def subscribe
    subscriber = current_organization.subscribers.find(params[:id])
    Billing::SubscriptionWorkflow.new(author: current_author).activate(subscriber: subscriber, plan: Billing::Plan.find(params.require(:plan_id)))
    redirect_to subscriber
  end
  def cancel
    subscriber = current_organization.subscribers.find(params[:id])
    Billing::SubscriptionWorkflow.new(author: current_author).cancel(subscriber.subscriptions.find(params[:subscription_id]))
    redirect_to subscriber
  end
end
