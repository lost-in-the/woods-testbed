class Organization < ApplicationRecord
  has_many :publications, dependent: :restrict_with_error
  has_many :memberships, dependent: :destroy
  has_many :authors, through: :memberships
  has_many :subscribers, dependent: :restrict_with_error
  has_many :activity_events, dependent: :destroy
  has_many :webhook_endpoints, dependent: :destroy
  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
end
