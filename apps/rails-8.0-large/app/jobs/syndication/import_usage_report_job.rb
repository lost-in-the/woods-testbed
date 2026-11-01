module Syndication
  class ImportUsageReportJob < ApplicationJob
    queue_as :syndication

    def perform(partner_id, rows)
      RecordUsage.new.call(partner: Partner.find(partner_id), rows: rows)
    end
  end
end
