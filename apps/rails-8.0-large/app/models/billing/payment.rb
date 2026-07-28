module Billing
  # STI base, and the one model carrying a state machine — so inlining
  # (Auditable), STI, and the aasm DSL all meet on a single class.
  class Payment < ApplicationRecord
    include AASM
    include Auditable

    self.table_name = "billing_payments"

    belongs_to :invoice, class_name: "Billing::Invoice"

    validates :amount_cents, numericality: { greater_than: 0 }

    aasm column: :state do
      state :pending, initial: true
      state :authorized
      state :captured
      state :failed

      event :authorize do
        transitions from: :pending, to: :authorized
      end

      event :capture do
        transitions from: :authorized, to: :captured
      end

      event :fail do
        transitions from: %i[pending authorized], to: :failed
      end
    end
  end
end
