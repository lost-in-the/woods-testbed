module ReferenceConcern
  extend ActiveSupport::Concern

  def reference_value
    ReferenceTarget.generate
  end
end
