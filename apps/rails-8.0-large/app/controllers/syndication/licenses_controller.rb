module Syndication
  class LicensesController < ApplicationController
    include CurrentTenant
    before_action :require_session
    before_action :require_editor

    def create
      partner = current_organization.syndication_partners.find(params.require(:partner_id))
      article = Article.joins(:publication).where(publications: { organization_id: current_organization.id }).find(params.require(:article_id))
      GrantLicense.new(author: current_author).call(partner: partner, article: article, territory: params.require(:territory),
        starts_on: params.require(:starts_on), ends_on: params.require(:ends_on), fee_cents: params.require(:fee_cents).to_i, exclusive: params[:exclusive] == '1')
      redirect_to syndication_partner_path(partner)
    end

    def revoke
      license = License.joins(:partner).where(syndication_partners: { organization_id: current_organization.id }).find(params[:id])
      RevokeLicense.new(author: current_author).call(license)
      redirect_to syndication_partner_path(license.partner)
    end
  end
end
