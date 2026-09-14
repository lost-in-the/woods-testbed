module Billing
  class SubscriptionWorkflow
    def initialize(author:)
      @author = author
    end
    def activate(subscriber:, plan:)
      authorize!(subscriber)
      Subscription.transaction do
        subscription = Subscription.find_or_initialize_by(subscriber: subscriber, plan: plan)
        if subscription.new_record?
          subscription.renews_at = Time.current + 30.days
          subscription.save!
          subscription.history.create!(event: 'activated', details: { plan: plan.name })
          issue(subscription, period: 'activation')
        end
        subscription
      end
    end
    def renew(subscription, at: Time.current)
      authorize!(subscription.subscriber)
      subscription.with_lock do
        return unless subscription.state == 'active' && subscription.renews_at <= at
        period = subscription.renews_at.utc.iso8601
        issue(subscription, period: period)
        subscription.update!(renews_at: subscription.renews_at + 30.days)
        subscription.history.create!(event: 'renewed', details: { period: period })
      end
    end
    def cancel(subscription)
      authorize!(subscription.subscriber)
      subscription.with_lock do
        return if subscription.state == 'canceled'
        subscription.update!(state: 'canceled')
        subscription.history.create!(event: 'canceled')
        RecordActivity.new.call(organization: subscription.subscriber.organization, actor: @author, subject: subscription, action: 'subscription.canceled')
      end
    end
    private
    def issue(subscription, period:)
      invoice = Invoice.create!(author: @author, subscriber: subscription.subscriber, subscription: subscription,
        reference: "SUB-#{subscription.id}-#{period}", due_at: Time.current + 7.days, currency: subscription.plan.currency)
      invoice.line_items.create!(description: "#{subscription.plan.name} / #{period}", amount_cents: subscription.plan.amount_cents)
      invoice
    end
    def authorize!(subscriber)
      raise Pundit::NotAuthorizedError unless @author&.editor_of?(subscriber.organization)
    end
  end
end
