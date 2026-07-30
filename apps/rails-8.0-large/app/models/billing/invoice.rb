module Billing
  class Invoice < ApplicationRecord
    include Archivable

    self.table_name = "billing_invoices"

    belongs_to :author
    has_many :line_items, class_name: "Billing::LineItem", dependent: :destroy
    has_many :payments, class_name: "Billing::Payment", dependent: :restrict_with_error

    validates :reference, presence: true, uniqueness: true

    scope :outstanding, -> { where(settled_at: nil) }

    def total_cents
      line_items.sum(:amount_cents)
    end
  end
end
