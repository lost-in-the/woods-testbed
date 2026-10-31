# The graph hub. Several models point here, so PageRank has something to rank
# and the dependents pass has real fan-in to resolve.
class Author < ApplicationRecord
  has_many :articles, dependent: :destroy
  has_many :comments, dependent: :nullify
  has_many :invoices, class_name: "Billing::Invoice", dependent: :restrict_with_error

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true

  scope :prolific, -> { joins(:articles).group(:id).having("COUNT(articles.id) > 5") }

  def display_name
    name.presence || email
  end
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :individual_profiles, class_name: 'Payouts::IndividualProfile', dependent: :restrict_with_error
  has_many :representations, class_name: 'Payouts::Representation', dependent: :destroy
  def editor_of?(organization)
    memberships.exists?(organization_id: organization.id, role: 'editor')
  end
end
