# Blog scenario (woods-testbed#38): the author of a post and the subscriber
# MailingListMailer writes to.
class User < ApplicationRecord
  has_many :posts, foreign_key: :author_id, inverse_of: :author, dependent: :nullify

  validates :name, :email, presence: true
end
