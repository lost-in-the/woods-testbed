# Audit trail, included only by the STI base so that inlining and STI
# interact rather than being exercised in separate files.
module Auditable
  extend ActiveSupport::Concern

  included do
    before_save :stamp_audit_fields
  end

  def audit_summary
    "#{self.class.name}##{id} last touched #{audited_at || 'never'}"
  end

  private

  def stamp_audit_fields
    self.audited_at = Time.current
  end
end
