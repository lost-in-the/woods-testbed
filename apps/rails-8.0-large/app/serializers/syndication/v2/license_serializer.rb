module Syndication
  module V2
    class LicenseSerializer < Syndication::LicenseSerializer
      attributes :id, :territory, :starts_on, :ends_on, :exclusive, :article, :usage

      def usage
        record.usage_reports.sort_by(&:period_start).map { |report| Syndication::UsageReportSerializer.new(report).as_json }
      end
    end
  end
end
