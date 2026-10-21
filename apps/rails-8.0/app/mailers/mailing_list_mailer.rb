# Blog scenario (woods-testbed#38). new_post assigns @user and @post; its HTML
# template also reads @preferences, which nothing assigns: the seeded
# unassigned-instance-variable bug Woods Map's passage flag must catch.
class MailingListMailer < ApplicationMailer
  def new_post(user, post)
    @user = user
    @post = post
    mail to: user.email, subject: "New post: #{post.title}"
  end
end
