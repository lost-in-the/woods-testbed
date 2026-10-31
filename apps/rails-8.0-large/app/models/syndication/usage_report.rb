module Syndication
  class UsageReport < ApplicationRecord
    self.table_name = 'syndication_usage_reports'
    belongs_to :license, class_name: 'Syndication::License'
    validates :period_start, :reported_at, presence: true
    validates :pickups, :impressions, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
