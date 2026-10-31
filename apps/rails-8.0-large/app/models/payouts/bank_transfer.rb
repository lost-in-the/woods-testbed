module Payouts
  class BankTransfer < Transfer
    store_accessor :destination, :account_last_four, :simulate_timeout
    validates :account_last_four, presence: true
  end
end
