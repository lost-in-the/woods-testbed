# A trivial job so the job extractor has a unit to produce.
class PublishPostJob < ApplicationJob
  def perform(post)
    post.update(status: :published)
  end
end
