# Placeholder seed model so rung 2's gate (`woods:extract` produces an index,
# `woods:validate` passes it) has something to extract.
#
# The kernel contract (rung 3, KERNEL_CONTRACT.md) defines the real model
# hierarchy and supersedes this. Do not build on Account.
class Account < ApplicationRecord
  has_many :account_events, dependent: :destroy

  validates :name, presence: true

  scope :active, -> { where(active: true) }
end
