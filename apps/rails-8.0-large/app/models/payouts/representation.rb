module Payouts
  class Representation < ApplicationRecord
    self.table_name = 'payouts_representations'
    belongs_to :agency_profile, class_name: 'Payouts::AgencyProfile'
    belongs_to :author
    validates :author_id, uniqueness: { scope: :agency_profile_id }
    validate do
      organization = agency_profile&.payee&.organization
      next unless organization && author
      errors.add(:author, 'must be a member of the agency organization') unless author.memberships.exists?(organization_id: organization.id)
      errors.add(:author, 'is already paid directly in this organization') if Payee.individual_for(author, organization)
    end
  end
end
