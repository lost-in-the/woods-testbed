module Syndication
  class RecordUsage
    def call(partner:, rows:)
      rows = rows.map { |row| row.to_h.with_indifferent_access }
      ids = rows.map { |row| row[:license_id].to_i }.uniq
      owned = partner.licenses.where(id: ids).pluck(:id)
      raise ActiveRecord::RecordNotFound, "License not found: #{(ids - owned).join(', ')}" unless (ids - owned).empty?
      now = Time.current
      records = rows.map do |row|
        UsageReport.new(license_id: row[:license_id].to_i, period_start: row[:period_start].to_date&.beginning_of_month,
          pickups: row[:pickups].to_i, impressions: row[:impressions].to_i, reported_at: now)
      end
      records.each(&:validate!)
      return 0 if records.empty?
      # upsert_all would stamp rows with the database clock; pass the app clock
      # so seeded and time-traveled rows stay reproducible.
      attributes = records.map { |r| r.slice(:license_id, :period_start, :pickups, :impressions, :reported_at).merge(created_at: now, updated_at: now) }
      UsageReport.upsert_all(attributes, unique_by: [:license_id, :period_start], record_timestamps: false,
        update_only: %i[pickups impressions reported_at updated_at])
      records.size
    end
  end
end
