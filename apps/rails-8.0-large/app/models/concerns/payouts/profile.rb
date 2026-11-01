module Payouts
  # Shared by the payee profile types behind Payee's delegated_type.
  module Profile
    extend ActiveSupport::Concern
    included do
      has_one :payee, as: :profile, class_name: 'Payouts::Payee', touch: true
    end
  end
end
