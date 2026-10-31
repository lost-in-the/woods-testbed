module Payouts
  class AgencyProfile < ApplicationRecord
    include Payouts::Profile
    self.table_name = 'payouts_agency_profiles'
    has_many :representations, class_name: 'Payouts::Representation', dependent: :destroy
    has_many :authors, through: :representations
    accepts_nested_attributes_for :representations
    normalizes :contact_email, with: ->(email) { email.strip.downcase }
    validates :name, :contact_email, presence: true
  end
end
