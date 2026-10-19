# Blog scenario (woods-testbed#38): tags through a join model, normalised
# before save. Inlined into Post by Woods; its callback runs inside Post's
# save chain.
module Taggable
  extend ActiveSupport::Concern

  included do
    has_many :taggings, dependent: :destroy
    has_many :tags, through: :taggings
    before_save :normalize_tags
  end

  def tag_list
    tags.map(&:name).join(", ")
  end

  private

  def normalize_tags
    tags.each { |tag| tag.name = tag.name.strip.downcase }
  end
end
