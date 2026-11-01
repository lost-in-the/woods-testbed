module Api
  class BaseController < ActionController::API
    include ActionController::HttpAuthentication::Token::ControllerMethods
    # Prepended so the partner is known before CurrentTenant reads current_organization.
    prepend_before_action :authenticate_partner!
    include CurrentTenant
    rescue_from ActiveRecord::RecordNotFound, with: -> { render json: { error: 'not_found' }, status: :not_found }

    def current_author = nil
    def current_organization = Current.partner&.organization

    private

    def authenticate_partner!
      partner = authenticate_with_http_token { |token, _options| partner_for(token) }
      return render json: { error: 'unauthorized' }, status: :unauthorized unless partner&.active?
      Current.partner = partner
    end

    def partner_for(token)
      candidate = Syndication::Partner.find_by(api_token: token)
      candidate if candidate && ActiveSupport::SecurityUtils.secure_compare(candidate.api_token, token)
    end
  end
end
