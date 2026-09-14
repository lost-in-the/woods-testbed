# No HTTP is performed. The first attempt fails, the next succeeds.
class WebhookDeliveryJob < ApplicationJob
  queue_as :webhooks
  def perform(delivery_id)
    delivery = WebhookDelivery.find(delivery_id)
    delivery.with_lock do
      return if delivery.state == 'delivered'
      attempts = delivery.attempts + 1
      delivery.update!(attempts: attempts, state: attempts == 1 ? 'failed' : 'delivered')
    end
  end
end
