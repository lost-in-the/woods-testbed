module Payouts
  class StartPayoutRun
    def initialize(author:)
      @author = author
    end

    def call(organization:, period_start:)
      raise Pundit::NotAuthorizedError unless @author&.editor_of?(organization)
      period_start = period_start.to_date.beginning_of_month
      PayoutRun.transaction do
        run = PayoutRun.find_by(organization: organization, period_start: period_start)
        return run if run
        run = PayoutRun.create!(organization: organization, period_start: period_start, started_by: @author)
        build_statements(run)
        run
      end
    rescue ActiveRecord::RecordNotUnique
      PayoutRun.find_by!(organization: organization, period_start: period_start)
    end

    private

    def build_statements(run)
      minimum = Rails.configuration.payouts.fetch(:minimum_payout_cents)
      cutoff = run.period_start.next_month
      earnings = Earning.unclaimed.joins(:payee)
        .where(payouts_payees: { organization_id: run.organization_id, status: Payee.statuses.fetch('active') })
        .where('payouts_earnings.earned_on < ?', cutoff)
      totals = earnings.group(:payee_id).sum(:amount_cents)
      payees = Payee.where(id: totals.keys).index_by(&:id)
      totals.sort.each do |payee_id, total|
        payee = payees.fetch(payee_id)
        if total < minimum
          run.statements.create!(payee: payee, status: :held, total_cents: total, currency: payee.currency, hold_reason: 'below_minimum')
        else
          statement = run.statements.create!(payee: payee, status: :draft, total_cents: total, currency: payee.currency)
          earnings.where(payee_id: payee_id).update_all(statement_id: statement.id)
        end
      end
    end
  end
end
