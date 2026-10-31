module Payouts
  # Returns nil for authors without a payee (editors, unpaid staff) and for
  # publications without a rate card.
  class AccrueArticleEarning
    def call(article)
      organization = article.publication.organization
      payee = Payee.for_author(article.author, organization)
      return nil unless payee
      earned_on = article.published_at.to_date
      rate_card = RateCard.current_for(article.publication, on: earned_on)
      return nil unless rate_card
      amount = Canopy::RoyaltyCalculator.new(rate_card: rate_card).article_fee_cents(word_count: article.word_count)
      AccrueEarning.new.call(payee: payee, source: article, kind: :article_fee, amount_cents: amount,
        earned_on: earned_on, description: "Article fee: #{article.title}")
    end
  end
end
