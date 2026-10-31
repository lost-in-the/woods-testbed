module Payouts
  class SubmitTransfer
    # The failed state is saved inside the lock; the error is raised after the
    # transaction commits, otherwise the rollback would erase the failure.
    def call(transfer, client: FakeLedgerClient.new)
      transient = nil
      transfer.with_lock do
        return transfer if transfer.settled? || transfer.rejected?
        transfer.attempts += 1
        begin
          result = client.create_transfer(idempotency_key: transfer.idempotency_key, amount_cents: transfer.amount_cents,
            currency: transfer.currency, destination: transfer.destination, attempt: transfer.attempts)
          transfer.provider_reference = result[:reference]
          transfer.last_error = nil
          transfer.settle!
          close(transfer, status: :paid)
        rescue FakeLedgerClient::Rejected => e
          transfer.last_error = e.message
          transfer.reject!
          close(transfer, status: :held, hold_reason: 'transfer_rejected')
          transfer.statement.earnings.update_all(statement_id: nil)
        rescue FakeLedgerClient::TransientError => e
          transfer.last_error = e.message
          transfer.fail!
          transient = e
        end
      end
      raise transient if transient
      transfer
    end

    private

    def close(transfer, **attributes)
      statement = transfer.statement
      run = statement.payout_run
      run.lock!
      statement.update!(**attributes)
      run.update!(status: :completed) unless run.statements.finalized.exists?
    end
  end
end
