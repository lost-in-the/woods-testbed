module Payouts
  class Representation < ApplicationRecord
    self.table_name = 'payouts_representations'
    belongs_to :agency_profile, class_name: 'Payouts::AgencyProfile'
    belongs_to :author
    validates :author_id, uniqueness: { scope: :agency_profile_id }
    validate do
      # Membership and direct-pay checks need the agency's organization, which
      # comes from its payee; without one they could not run at all.
      organization = agency_profile&.payee&.organization
      next errors.add(:agency_profile, 'needs a payee before it can represent authors') unless organization
      next unless author
      errors.add(:author, 'must be a member of the agency organization') unless author.memberships.exists?(organization_id: organization.id)
      errors.add(:author, 'is already paid directly in this organization') if Payee.individual_for(author, organization)
    end
  end
end
