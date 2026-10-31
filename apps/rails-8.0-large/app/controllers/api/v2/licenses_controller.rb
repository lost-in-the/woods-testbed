module Api
  module V2
    class LicensesController < Api::BaseController
      def index
        licenses = Current.partner.licenses.active_on(Date.current).includes(:article, :usage_reports).order(:id)
        render json: { data: licenses.map { |license| Syndication::V2::LicenseSerializer.new(license).as_json }, meta: { count: licenses.size } }
      end

      def show
        render json: { data: Syndication::V2::LicenseSerializer.new(Current.partner.licenses.find(params[:id])).as_json }
      end
    end
  end
end
