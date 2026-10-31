module Payouts
  class WalletTransfer < Transfer
    store_accessor :destination, :wallet_handle, :simulate_timeout
    validates :wallet_handle, presence: true
  end
end
