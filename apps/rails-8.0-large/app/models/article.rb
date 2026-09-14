class Article < ApplicationRecord
  include Archivable

  belongs_to :publication
  has_many :revisions, class_name: 'ArticleRevision', dependent: :destroy
  has_many :collection_articles, dependent: :destroy
  has_many :collections, through: :collection_articles
  validates :state, inclusion: { in: %w[draft in_review changes_requested approved scheduled published] }
  validate do
    errors.add(:author, 'must belong to this organization') unless author&.memberships&.exists?(organization_id: publication&.organization_id)
  end

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

  def latest_revision
    revisions.order(number: :desc).first
  end

  private

  def derive_slug
    self.slug ||= WoodsTestbed::Slug.call(title)
  end

end
