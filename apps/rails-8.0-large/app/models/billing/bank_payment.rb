module Billing
  class BankPayment < Payment
    validates :sort_code, presence: true
  end
end
