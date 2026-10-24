# A blog post. Exercises associations, scopes, validations, an enum, and a
# callback so extraction has real behavioral metadata to resolve on Rails 6.0.
#
# Blog scenario (woods-testbed#38), as in rails-8.0: the Taggable concern, a
# slug set before save, and an after_commit that enqueues NotifySubscribersJob,
# which has no retry policy.
class Post < ApplicationRecord
  include Taggable

  belongs_to :author, class_name: "User", optional: true
  has_many :comments, dependent: :destroy

  enum status: { draft: 0, published: 1 }

  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }

  before_save :normalize_title
  before_save :set_slug, if: :title_changed?
  after_commit :notify_subscribers, on: :create

  def normalize_title
    self.title = title.to_s.strip
  end

  private

  def set_slug
    self.slug = title.parameterize
  end

  def notify_subscribers
    NotifySubscribersJob.perform_later(id)
  end
end
