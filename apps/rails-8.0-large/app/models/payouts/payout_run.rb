module Payouts
  class PayoutRun < ApplicationRecord
    self.table_name = 'payouts_payout_runs'
    belongs_to :organization
    belongs_to :started_by, class_name: 'Author'
    has_many :statements, class_name: 'Payouts::Statement', dependent: :destroy
    enum :status, { drafted: 0, finalized: 1, completed: 2 }
    validates :period_start, presence: true, uniqueness: { scope: :organization_id }
    validate { errors.add(:period_start, 'must be the first day of a month') if period_start && period_start.day != 1 }

    def period_end = period_start.end_of_month
  end
end
