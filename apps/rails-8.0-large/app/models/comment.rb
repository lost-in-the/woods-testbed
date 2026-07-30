class Comment < ApplicationRecord
  include Archivable

  belongs_to :article
  belongs_to :author, optional: true

  validates :body, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
