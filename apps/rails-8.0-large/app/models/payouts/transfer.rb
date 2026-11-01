module Payouts
  # STI base. InternationalBankTransfer < BankTransfer < Transfer gives the
  # inheritance chain a grandchild.
  class Transfer < ApplicationRecord
    include AASM
    include Canopy::MoneyColumns
    self.table_name = 'payouts_transfers'
    CLASSES = { 'bank' => 'Payouts::BankTransfer', 'international_bank' => 'Payouts::InternationalBankTransfer', 'wallet' => 'Payouts::WalletTransfer' }.freeze

    belongs_to :statement, class_name: 'Payouts::Statement'
    money_column :amount_cents
    validates :idempotency_key, presence: true, uniqueness: true
    validates :statement_id, uniqueness: true
    after_commit :enqueue_submission, on: :create

    aasm column: :state do
      state :pending, initial: true
      state :failed
      state :settled
      state :rejected

      event :fail do
        transitions from: %i[pending failed], to: :failed
      end
      event :settle do
        transitions from: %i[pending failed], to: :settled
      end
      event :reject do
        transitions from: %i[pending failed], to: :rejected
      end
    end

    def self.class_for(payout_method) = CLASSES.fetch(payout_method.to_s).constantize

    private

    def enqueue_submission
      Payouts::SubmitTransferJob.perform_later(id)
    end
  end
end
