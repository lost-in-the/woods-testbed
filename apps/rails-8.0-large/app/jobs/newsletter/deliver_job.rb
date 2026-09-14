module Newsletter
  class DeliverJob < ApplicationJob
    queue_as :newsletter
    def perform(delivery_id)
      delivery = Delivery.find(delivery_id)
      delivery.with_lock do
        return unless delivery.state == 'queued'
        bounce = delivery.subscriber.preferences['simulate_bounce'] == true
        delivery.update!(state: bounce ? 'bounced' : 'delivered', delivered_at: bounce ? nil : Time.current)
      end
    end
  end
end
