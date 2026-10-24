# Blog scenario (woods-testbed#38): enqueued from Post's after_commit on create.
# Deliberately declares no retry_on or discard_on, so an exception in the
# mailer loses the notification (the "job without retry" finding).
class NotifySubscribersJob < ApplicationJob
  queue_as :mailers

  def perform(post_id)
    post = Post.find(post_id)
    User.where.not(id: post.author_id).find_each do |subscriber|
      MailingListMailer.new_post(subscriber, post).deliver_later
    end
  end
end
