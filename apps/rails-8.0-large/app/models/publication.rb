class Publication < ApplicationRecord
  belongs_to :organization
  has_many :articles, dependent: :restrict_with_error
  has_many :collections, dependent: :destroy
  has_many :plans, class_name: 'Billing::Plan', dependent: :restrict_with_error
  has_many :campaigns, class_name: 'Newsletter::Campaign', dependent: :destroy
  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
end
