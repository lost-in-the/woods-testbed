module Syndication
  class Partner < ApplicationRecord
    self.table_name = 'syndication_partners'
    belongs_to :organization
    has_many :licenses, class_name: 'Syndication::License', dependent: :restrict_with_error
    has_secure_token :api_token
    encrypts :webhook_secret, deterministic: true
    normalizes :contact_email, with: ->(email) { email.strip.downcase }
    enum :status, { active: 0, suspended: 1 }
    validates :name, :contact_email, presence: true
  end
end
