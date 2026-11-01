module Payouts
  class StatementSerializer < ApplicationSerializer
    attributes :id, :status, :total_cents, :currency, :payee_name, :hold_reason, :period_start

    def id = record.id
    def status = record.status
    def total_cents = record.total_cents
    def currency = record.currency
    def payee_name = record.payee.display_name
    def hold_reason = record.hold_reason
    def period_start = record.payout_run.period_start
  end
end
