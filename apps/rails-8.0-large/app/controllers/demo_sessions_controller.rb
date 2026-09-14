class DemoSessionsController < ApplicationController
  before_action :demo_only
  def show
    @authors = Author.joins(:memberships).distinct.order(:name)
  end
  def create
    author = Author.joins(:memberships).find(params.require(:author_id))
    reset_session
    session[:author_id] = author.id
    redirect_to root_path
  end
  def update
    organization = current_author&.organizations&.find(params.require(:organization_id))
    raise Pundit::NotAuthorizedError unless organization
    session[:organization_id] = organization.id
    redirect_to root_path
  end
  def destroy
    reset_session
    redirect_to demo_session_path
  end
  private
  def demo_only
    head :not_found unless Rails.env.development? || Rails.env.test?
  end
end
