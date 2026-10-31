module Payouts
  class StatementPolicy < ApplicationPolicy
    def index? = user.present? && user.editor_of?(record.payout_run.organization)
    def show? = user.present? && (index? || own_statement? || represented?)

    private

    def payee = record.payee
    def own_statement? = payee.payouts_individual_profile? && payee.profile.author_id == user.id
    def represented? = payee.payouts_agency_profile? && payee.profile.representations.exists?(author_id: user.id)
  end
end
