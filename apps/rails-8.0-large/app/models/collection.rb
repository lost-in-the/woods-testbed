class Collection < ApplicationRecord
  belongs_to :publication
  has_many :collection_articles, -> { order(:position) }, dependent: :destroy
  has_many :articles, through: :collection_articles
  validates :name, presence: true
end
