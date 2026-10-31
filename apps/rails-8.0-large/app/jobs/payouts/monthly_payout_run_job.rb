module Payouts
  class MonthlyPayoutRunJob < ApplicationJob
    queue_as :payouts

    def perform(at = Time.current)
      period_start = at.to_date.beginning_of_month.prev_month
      Organization.find_each do |organization|
        editor = organization.authors.merge(Membership.where(role: 'editor')).order('memberships.id').first
        next unless editor
        Payouts::StartPayoutRun.new(author: editor).call(organization: organization, period_start: period_start)
      end
    end
  end
end
