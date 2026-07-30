module Billing
  class CardPayment < Payment
    validates :last_four, presence: true
  end
end
