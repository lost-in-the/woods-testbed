module Api
  module V1
    class LicensesController < Api::BaseController
      def index
        licenses = Current.partner.licenses.active_on(Date.current).includes(:article).order(:id)
        render json: { licenses: licenses.map { |license| Syndication::LicenseSerializer.new(license).as_json } }
      end

      def show
        render json: { license: Syndication::LicenseSerializer.new(Current.partner.licenses.find(params[:id])).as_json }
      end
    end
  end
end
