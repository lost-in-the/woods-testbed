class Organization < ApplicationRecord
  has_many :publications, dependent: :restrict_with_error
  has_many :memberships, dependent: :destroy
  has_many :authors, through: :memberships
  has_many :subscribers, dependent: :restrict_with_error
  has_many :activity_events, dependent: :destroy
  has_many :webhook_endpoints, dependent: :destroy
  has_many :payees, class_name: 'Payouts::Payee', dependent: :restrict_with_error
  has_many :payout_runs, class_name: 'Payouts::PayoutRun', dependent: :restrict_with_error
  has_many :syndication_partners, class_name: 'Syndication::Partner', dependent: :restrict_with_error
  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
end
