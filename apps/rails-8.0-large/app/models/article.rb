class Article < ApplicationRecord
  include Archivable

  belongs_to :author
  has_many :comments, dependent: :destroy
  has_many :article_tags, dependent: :destroy
  has_many :tags, through: :article_tags

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :published, -> { where.not(published_at: nil) }

  before_validation :derive_slug

  def word_count
    WordCount.new(body.to_s).total
  end

  private

  def derive_slug
    self.slug ||= WoodsTestbed::Slug.call(title)
  end
end
