class WebhookEndpoint < ApplicationRecord
  belongs_to :organization
  has_many :webhook_deliveries, dependent: :destroy
  validates :url, :secret, presence: true
end
