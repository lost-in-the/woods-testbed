# Blog scenario (woods-testbed#38): the unit Woods Map's design study reads.
# The after_commit enqueues NotifySubscribersJob, which has no retry policy.
class Post < ApplicationRecord
  include Taggable

  belongs_to :author, class_name: "User"
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { maximum: 140 }

  before_save :set_slug, if: :title_changed?
  after_commit :notify_subscribers, on: :create

  scope :published, -> { where(state: "published").where.not(published_at: nil) }

  def publish!
    update!(state: "published", published_at: Time.current)
  end

  def to_param
    slug.presence || super
  end

  private

  def set_slug
    self.slug = title.parameterize
  end

  def notify_subscribers
    NotifySubscribersJob.perform_later(id)
  end
end
