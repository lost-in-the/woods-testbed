module Api
  module V2
    class UsageReportsController < Api::BaseController
      def create
        rows = params.permit(reports: %i[license_id period_start pickups impressions]).fetch(:reports, []).map { |row| row.to_h.to_hash }
        Syndication::ImportUsageReportJob.perform_later(Current.partner.id, rows)
        render json: { accepted: rows.size }, status: :accepted
      end
    end
  end
end
