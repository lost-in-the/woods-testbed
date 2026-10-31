module Payouts
  class IndividualProfile < ApplicationRecord
    include Payouts::Profile
    self.table_name = 'payouts_individual_profiles'
    belongs_to :author
    encrypts :tax_id, deterministic: true
    normalizes :tax_id, with: ->(value) { value.gsub(/\D/, '') }
    store_accessor :bank_details, :account_last_four, :iban_last_four, :swift_code, :wallet_handle, :simulate_timeout
    validates :legal_name, presence: true
  end
end
