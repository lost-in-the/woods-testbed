module Billing
  class LineItem < ApplicationRecord
    self.table_name = "billing_line_items"

    belongs_to :invoice, class_name: "Billing::Invoice"

    validates :description, presence: true
    validates :amount_cents, numericality: { greater_than_or_equal_to: 0 }
  end
end
