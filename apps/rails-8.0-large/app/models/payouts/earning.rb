module Payouts
  class Earning < ApplicationRecord
    include Canopy::MoneyColumns
    self.table_name = 'payouts_earnings'
    belongs_to :payee, class_name: 'Payouts::Payee'
    belongs_to :source, polymorphic: true
    belongs_to :statement, class_name: 'Payouts::Statement', optional: true
    money_column :amount_cents
    enum :kind, { article_fee: 0, syndication_share: 1 }
    validates :source_type, inclusion: { in: %w[Article Syndication::License] }
    validates :earned_on, :description, presence: true
    scope :unclaimed, -> { where(statement_id: nil) }
  end
end
