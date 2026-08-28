# A blog post. Exercises associations, scopes, validations, an enum, and a
# callback so extraction has real behavioral metadata to resolve on Rails 6.0.
class Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  enum status: { draft: 0, published: 1 }

  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }

  before_save :normalize_title

  def normalize_title
    self.title = title.to_s.strip
  end
end
