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
end
