module Syndication
  class License < ApplicationRecord
    include Canopy::MoneyColumns
    self.table_name = 'syndication_licenses'
    # Revoked licenses disappear everywhere, the partner API included. Reach
    # them with unscoped.
    default_scope { where(revoked_at: nil) }

    belongs_to :partner, class_name: 'Syndication::Partner'
    belongs_to :article
    belongs_to :granted_by, class_name: 'Author', default: -> { Current.author }
    has_many :usage_reports, class_name: 'Syndication::UsageReport', dependent: :destroy
    money_column :fee_cents
    validates :territory, :starts_on, :ends_on, presence: true
    scope :active_on, ->(date) { where('starts_on <= ? AND ends_on >= ?', date, date) }
    validate do
      errors.add(:article, 'must be published') unless article&.state == 'published'
      errors.add(:partner, 'must belong to the article organization') unless partner && partner.organization_id == article&.publication&.organization_id
      errors.add(:ends_on, 'must be on or after the start') if starts_on && ends_on && ends_on < starts_on
      errors.add(:base, 'conflicts with an exclusive license for this article') if exclusive_conflict?
    end

    def revoked? = revoked_at.present?

    private

    def exclusive_conflict?
      return false unless article && starts_on && ends_on
      overlapping = License.where(article: article).where.not(id: id)
        .where('starts_on <= ? AND ends_on >= ?', ends_on, starts_on)
        .where("territory = :territory OR territory = 'worldwide' OR :territory = 'worldwide'", territory: territory)
      exclusive? ? overlapping.exists? : overlapping.where(exclusive: true).exists?
    end
  end
end
