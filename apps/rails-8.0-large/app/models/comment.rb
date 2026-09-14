class Comment < ApplicationRecord
  include Archivable

  belongs_to :article, counter_cache: true
  belongs_to :author, optional: true

  validates :body, presence: true

  scope :recent, -> { order(created_at: :desc) }
  belongs_to :parent, class_name: 'Comment', optional: true
  has_many :replies, class_name: 'Comment', foreign_key: :parent_id, dependent: :nullify
  validate do
    errors.add(:parent, 'must belong to this article') if parent && parent.article_id != article_id
    seen = [id].compact
    node = parent
    while node
      if seen.include?(node.id)
        errors.add(:parent, 'cannot create a cycle')
        break
      end
      seen << node.id
      node = node.parent
    end
    errors.add(:author, 'must belong to organization') if author && !author.memberships.exists?(organization_id: article&.publication&.organization_id)
  end
end
