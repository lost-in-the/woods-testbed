module Payouts
  class PayeesController < ApplicationController
    include CurrentTenant
    before_action :require_session
    before_action :require_editor
    BANK_FIELDS = %i[account_last_four iban_last_four swift_code wallet_handle simulate_timeout].freeze

    def index
      @payees = scope.includes(:profile).order(:display_name).limit(25).offset(page_offset)
      @authors = current_organization.authors.order(:name)
    end

    def show
      @payee = scope.find(params[:id])
      @statements = @payee.statements.includes(:payout_run).order(id: :desc)
    end

    def create
      payee = Payee.transaction { params[:kind] == 'agency' ? create_agency : create_individual }
      redirect_to payouts_payee_path(payee)
    end

    private

    def scope = current_organization.payees

    def create_individual
      author = current_organization.authors.find(params.require(:author_id))
      profile = IndividualProfile.create!(author: author, legal_name: params.require(:legal_name), tax_id: params[:tax_id].presence,
        **params.permit(*BANK_FIELDS).to_h.symbolize_keys.compact_blank)
      Payee.create!(organization: current_organization, profile: profile, display_name: author.name, payout_method: params.fetch(:payout_method, 'bank'))
    end

    # The payee must exist before representations are saved: Representation
    # validates against the payee's organization.
    def create_agency
      profile = AgencyProfile.create!(name: params.require(:name), contact_email: params.require(:contact_email))
      payee = Payee.create!(organization: current_organization, profile: profile, display_name: profile.name, payout_method: params.fetch(:payout_method, 'bank'))
      rows = params.permit(representations_attributes: [:author_id]).fetch(:representations_attributes, {}).to_h.values.select { |row| row['author_id'].present? }
      profile.update!(representations_attributes: rows)
      payee
    end
  end
end
