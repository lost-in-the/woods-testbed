module Payouts
  class ReconcileTransfersJob < ApplicationJob
    queue_as :payouts

    def perform
      Payouts::Transfer.failed.find_each { |transfer| Payouts::SubmitTransferJob.perform_later(transfer.id) }
    end
  end
end
