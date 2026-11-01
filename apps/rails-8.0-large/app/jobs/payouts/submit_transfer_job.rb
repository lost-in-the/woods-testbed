module Payouts
  class SubmitTransferJob < ApplicationJob
    queue_as :payouts
    retry_on Payouts::FakeLedgerClient::TransientError, wait: 5.minutes, attempts: Rails.configuration.payouts[:transfer_retry_attempts]
    discard_on ActiveRecord::RecordNotFound

    def perform(transfer_id)
      Payouts::SubmitTransfer.new.call(Payouts::Transfer.find(transfer_id))
    end
  end
end
