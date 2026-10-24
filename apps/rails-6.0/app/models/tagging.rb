# Blog scenario (woods-testbed#38): the join model behind Taggable.
class Tagging < ApplicationRecord
  belongs_to :post
  belongs_to :tag
end
