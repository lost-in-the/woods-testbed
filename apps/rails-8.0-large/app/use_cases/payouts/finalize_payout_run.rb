module Payouts
  class FinalizePayoutRun
    DESTINATION_KEYS = %w[account_last_four iban_last_four swift_code wallet_handle simulate_timeout].freeze

    def initialize(author:)
      @author = author
    end

    def call(run)
      raise Pundit::NotAuthorizedError unless @author&.editor_of?(run.organization)
      finalized = []
      run.with_lock do
        return run unless run.drafted?
        run.statements.draft.includes(payee: :profile).find_each do |statement|
          statement.update!(status: :finalized)
          create_transfer(statement)
          finalized << statement
        end
        run.update!(status: :finalized, finalized_at: Time.current)
      end
      # Mail only once the run has committed, so a failure partway through
      # never tells contributors about statements that rolled back.
      finalized.each { |statement| ContributorMailer.statement_ready(statement).deliver_later }
      run
    end

    private

    def create_transfer(statement)
      payee = statement.payee
      Transfer.class_for(payee.payout_method).create!(statement: statement, amount_cents: statement.total_cents,
        currency: statement.currency, idempotency_key: "statement-#{statement.id}", destination: destination_for(payee))
    end

    def destination_for(payee)
      return { 'account_last_four' => '7000' } if payee.payouts_agency_profile?
      (payee.profile.bank_details || {}).slice(*DESTINATION_KEYS).compact_blank
    end
  end
end
