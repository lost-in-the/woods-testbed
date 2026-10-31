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
    DESTINATION_FIELDS = {
      'bank' => %w[account_last_four],
      'international_bank' => %w[account_last_four iban_last_four swift_code],
      'wallet' => %w[wallet_handle]
    }.freeze
    scope :in_current_organization, -> { where(organization: Current.organization) }
    validate :agencies_paid_by_bank, if: :payouts_agency_profile?
    validate :individual_belongs_to_organization, if: -> { payouts_individual_profile? && organization }

    def missing_destination_fields
      return [] unless payouts_individual_profile?
      DESTINATION_FIELDS.fetch(payout_method, []).reject { |field| profile.bank_details.to_h[field].present? }
    end

    def self.agency_for(author, organization)
      joins('INNER JOIN payouts_representations ON payouts_representations.agency_profile_id = payouts_payees.profile_id')
        .where(organization: organization, profile_type: 'Payouts::AgencyProfile', payouts_representations: { author_id: author.id })
        .order(:id).first
    end

    def self.individual_for(author, organization)
      joins('INNER JOIN payouts_individual_profiles ON payouts_individual_profiles.id = payouts_payees.profile_id')
        .where(organization: organization, profile_type: 'Payouts::IndividualProfile', payouts_individual_profiles: { author_id: author.id })
        .order(:id).first
    end

    def self.for_author(author, organization)
      agency_for(author, organization) || individual_for(author, organization)
    end

    private

    def agencies_paid_by_bank
      errors.add(:payout_method, 'must be bank for an agency') unless payout_method == 'bank'
    end

    # Transfers copy these details at finalize; checking here keeps one bad
    # payee from failing the whole payout run.
    def individual_belongs_to_organization
      author = profile.author
      errors.add(:profile, 'author must be a member of this organization') unless author.memberships.exists?(organization_id: organization_id)
      errors.add(:profile, 'author is represented by an agency in this organization') if Payee.agency_for(author, organization)
      existing = Payee.individual_for(author, organization)
      errors.add(:profile, 'author already has a payee in this organization') if existing && existing != self
      missing = missing_destination_fields
      errors.add(:payout_method, "needs #{missing.join(', ')}") if missing.any?
    end
  end
end
