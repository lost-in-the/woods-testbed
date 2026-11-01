module Payouts
  class Statement < ApplicationRecord
    include Canopy::MoneyColumns
    self.table_name = 'payouts_statements'
    belongs_to :payout_run, class_name: 'Payouts::PayoutRun', counter_cache: :statements_count
    belongs_to :payee, class_name: 'Payouts::Payee'
    has_many :earnings, class_name: 'Payouts::Earning', dependent: :nullify
    has_one :transfer, class_name: 'Payouts::Transfer', dependent: :restrict_with_error
    money_column :total_cents
    enum :status, { draft: 0, held: 1, finalized: 2, paid: 3 }
    validates :payee_id, uniqueness: { scope: :payout_run_id }
    validate { errors.add(:payee, 'must belong to the payout run organization') unless payee&.organization_id == payout_run&.organization_id }
  end
end
