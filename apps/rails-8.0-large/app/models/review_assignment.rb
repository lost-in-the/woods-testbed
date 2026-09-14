class ReviewAssignment < ApplicationRecord
  belongs_to :article_revision
  belongs_to :reviewer, class_name: 'Author'
  has_one :review_decision, dependent: :destroy
  validates :reviewer_id, uniqueness: { scope: :article_revision_id }
  validate do
    unless reviewer&.memberships&.exists?(organization_id: article_revision&.article&.publication&.organization_id, role: 'editor')
      errors.add(:reviewer, 'must be an editor of this organization')
    end
  end
end
