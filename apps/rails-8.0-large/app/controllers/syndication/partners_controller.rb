module Syndication
  class PartnersController < ApplicationController
    include CurrentTenant
    before_action :require_session
    before_action :require_editor

    def index
      @partners = scope.order(:name).limit(25).offset(page_offset)
    end

    def show
      @partner = scope.find(params[:id])
      @licenses = @partner.licenses.includes(:article).order(id: :desc)
      @articles = Article.joins(:publication).where(publications: { organization_id: current_organization.id }, state: 'published').order(:title)
    end

    def create
      partner = scope.create!(name: params.require(:name), contact_email: params.require(:contact_email))
      redirect_to syndication_partner_path(partner)
    end

    private

    def scope = current_organization.syndication_partners
  end
end
