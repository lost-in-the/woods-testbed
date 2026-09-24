# frozen_string_literal: true

class ReferenceAssignedCaller
  def self.values
    [ReferenceValueOwner::Criteria, ReferenceValueOwner::Page,
     ReferenceAssigned::Criteria, ReferenceAssigned::Page,
     ReferenceLibraryValues::Criteria, ReferenceLibraryValues::Page]
  end
end
