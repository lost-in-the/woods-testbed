module Syndication
  class GrantLicense
    def initialize(author:)
      @author = author
    end

    def call(partner:, article:, territory:, starts_on:, ends_on:, fee_cents:, exclusive: false)
      organization = partner.organization
      raise Pundit::NotAuthorizedError unless @author&.editor_of?(organization)
      License.transaction do
        license = License.create!(partner: partner, article: article, granted_by: @author, territory: territory,
          starts_on: starts_on, ends_on: ends_on, fee_cents: fee_cents, exclusive: exclusive)
        RecordActivity.new.call(organization: organization, actor: @author, subject: license, action: 'license.granted')
        accrue_share(license, organization)
        license
      end
    end

    private

    def accrue_share(license, organization)
      payee = Payouts::Payee.for_author(license.article.author, organization)
      return unless payee
      Payouts::AccrueEarning.new.call(payee: payee, source: license, kind: :syndication_share,
        amount_cents: Canopy::RoyaltyCalculator.new.syndication_share_cents(fee_cents: license.fee_cents),
        earned_on: license.starts_on, description: "Syndication share: #{license.article.title}")
    end
  end
end
