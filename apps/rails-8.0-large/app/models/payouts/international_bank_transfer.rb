module Payouts
  class InternationalBankTransfer < BankTransfer
    store_accessor :destination, :iban_last_four, :swift_code
    validates :iban_last_four, :swift_code, presence: true
  end
end
