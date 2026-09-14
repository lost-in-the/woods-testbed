class ReviewDecision < ApplicationRecord
  belongs_to :review_assignment
  validates :outcome, inclusion: { in: %w[approved changes_requested] }
  validates :review_assignment_id, uniqueness: true
  validate { errors.add(:base, 'Decisions are immutable') if persisted? && changed? }
end
