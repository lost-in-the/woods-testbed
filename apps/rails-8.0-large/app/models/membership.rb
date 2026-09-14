class Membership < ApplicationRecord
  belongs_to :organization
  belongs_to :author
  validates :role, inclusion: { in: %w[author editor] }
  validates :author_id, uniqueness: { scope: :organization_id }
end
