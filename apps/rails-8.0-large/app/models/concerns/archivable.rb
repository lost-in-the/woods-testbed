# Soft-archiving, included by three models.
#
# Three is deliberate (KERNEL_CONTRACT.md): concern inlining is what Woods does
# that file-level tools don't, and one includer wouldn't exercise it. The
# contract smoke asserts the count exactly.
module Archivable
  extend ActiveSupport::Concern

  included do
    scope :archived,     -> { where.not(archived_at: nil) }
    scope :not_archived, -> { where(archived_at: nil) }

    before_save :clear_archived_at_when_reactivated
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def archived?
    archived_at.present?
  end

  private

  def clear_archived_at_when_reactivated
    self.archived_at = nil if respond_to?(:active) && active? && archived?
  end
end
