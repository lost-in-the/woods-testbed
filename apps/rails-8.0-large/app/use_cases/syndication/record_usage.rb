module Syndication
  class RecordUsage
    def call(partner:, rows:)
      rows = rows.map { |row| row.to_h.with_indifferent_access }
      ids = rows.map { |row| row[:license_id].to_i }.uniq
      owned = partner.licenses.where(id: ids).pluck(:id)
      raise ActiveRecord::RecordNotFound, "License not found: #{(ids - owned).join(', ')}" unless (ids - owned).empty?
      now = Time.current
      records = rows.map do |row|
        UsageReport.new(license_id: row[:license_id].to_i, period_start: row[:period_start],
          pickups: row[:pickups].to_i, impressions: row[:impressions].to_i, reported_at: now)
      end
      records.each(&:validate!)
      return 0 if records.empty?
      attributes = records.map { |r| r.slice(:license_id, :period_start, :pickups, :impressions, :reported_at) }
      UsageReport.upsert_all(attributes, unique_by: [:license_id, :period_start])
      records.size
    end
  end
end
