# Blog scenario (woods-testbed#38).
class Comment < ApplicationRecord
  belongs_to :post, counter_cache: true
  belongs_to :user

  validates :body, presence: true
end
