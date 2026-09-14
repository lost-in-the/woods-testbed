class ArticleRevision < ApplicationRecord
  belongs_to :article
  belongs_to :author
  has_many :review_assignments, dependent: :destroy
  validates :title, :number, presence: true
  validates :number, uniqueness: { scope: :article_id }
  validate { errors.add(:base, 'Revisions are immutable') if persisted? && changed? }
  validate { errors.add(:author, 'must belong to the organization') unless author&.memberships&.exists?(organization_id: article&.publication&.organization_id) }
end
