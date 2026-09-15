class RenewSubscriptionsJob < ApplicationJob
  queue_as :billing
  def perform
    Billing::Subscription.active.where('renews_at <= ?', Time.current).find_each do |subscription|
      editor = subscription.subscriber.organization.memberships.find_by!(role: 'editor').author
      Billing::SubscriptionWorkflow.new(author: editor).renew(subscription)
    end
  end
end
