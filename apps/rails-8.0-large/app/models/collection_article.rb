class CollectionArticle < ApplicationRecord
  belongs_to :collection
  belongs_to :article
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :article_id, uniqueness: { scope: :collection_id }
  validate { errors.add(:article, 'must belong to this publication') unless article&.publication_id == collection&.publication_id }
end
