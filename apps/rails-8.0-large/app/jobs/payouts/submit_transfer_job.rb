module Payouts
  class SubmitTransferJob < ApplicationJob
    queue_as :payouts
    def perform(transfer_id); end
  end
end
