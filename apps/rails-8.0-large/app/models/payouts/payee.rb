module Payouts
  class Payee < ApplicationRecord
    self.table_name = 'payouts_payees'
    belongs_to :organization
    delegated_type :profile, types: %w[Payouts::IndividualProfile Payouts::AgencyProfile]
    has_many :earnings, class_name: 'Payouts::Earning', dependent: :restrict_with_error
    has_many :statements, class_name: 'Payouts::Statement', dependent: :restrict_with_error
    enum :status, { active: 0, paused: 1 }
    validates :display_name, presence: true
    validates :payout_method, inclusion: { in: %w[bank international_bank wallet] }
    scope :in_current_organization, -> { where(organization: Current.organization) }
    validate do
      next unless payouts_individual_profile? && organization
      if Payee.agency_for(profile.author, organization)
        errors.add(:profile, 'author is represented by an agency in this organization')
      end
    end

    def self.agency_for(author, organization)
      joins('INNER JOIN payouts_representations ON payouts_representations.agency_profile_id = payouts_payees.profile_id')
        .where(organization: organization, profile_type: 'Payouts::AgencyProfile', payouts_representations: { author_id: author.id })
        .first
    end

    def self.individual_for(author, organization)
      joins('INNER JOIN payouts_individual_profiles ON payouts_individual_profiles.id = payouts_payees.profile_id')
        .where(organization: organization, profile_type: 'Payouts::IndividualProfile', payouts_individual_profiles: { author_id: author.id })
        .first
    end

    def self.for_author(author, organization)
      agency_for(author, organization) || individual_for(author, organization)
    end
  end
end
