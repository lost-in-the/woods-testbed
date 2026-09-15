module Newsletter
  class Campaign < ApplicationRecord
    self.table_name = "newsletter_campaigns"
    belongs_to :publication
    belongs_to :article
    has_many :deliveries, class_name: 'Newsletter::Delivery', dependent: :destroy
    validates :subject, presence: true
    validates :state, inclusion: { in: %w[draft sent] }
    validate { errors.add(:article, 'must be published in this publication') unless article&.publication_id == publication_id && article&.state == 'published' }
    def recipients
      Subscriber.joins(subscriptions: :plan).where(billing_subscriptions: { state: 'active' }, billing_plans: { publication_id: publication_id }).distinct
    end
  end
end
