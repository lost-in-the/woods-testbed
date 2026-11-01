module Syndication
  class UsageReportSerializer < ApplicationSerializer
    attributes :period_start, :pickups, :impressions

    def period_start = record.period_start
    def pickups = record.pickups
    def impressions = record.impressions
  end
end
