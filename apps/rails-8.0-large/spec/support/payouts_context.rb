# Builders for payout and syndication specs. Call setup_canopy first.
module PayoutsContext
  def individual_payee(author = @writer, organization: @organization, payout_method: 'bank', **bank_details)
    profile = Payouts::IndividualProfile.create!(author: author, legal_name: author.name, tax_id: '123-45-6789',
      bank_details: { 'account_last_four' => '4321' }.merge(bank_details.transform_keys(&:to_s)))
    Payouts::Payee.create!(organization: organization, profile: profile, display_name: author.name, payout_method: payout_method)
  end

  def agency_payee(*authors, name: 'Riverbank Agency', organization: @organization)
    profile = Payouts::AgencyProfile.create!(name: name, contact_email: 'desk@riverbank.test')
    payee = Payouts::Payee.create!(organization: organization, profile: profile, display_name: name)
    authors.each { |author| profile.representations.create!(author: author) }
    payee
  end

  def rate_card(publication = @publication, basis: 'per_word', effective_on: Date.new(2026, 1, 1), **terms)
    terms = { cents_per_word: 4 }.merge(terms) if basis == 'per_word'
    publication.rate_cards.create!(basis: basis, effective_on: effective_on, terms: terms.transform_keys(&:to_s))
  end

  def partner(organization = @organization, name: 'Valley Courier')
    organization.syndication_partners.create!(name: name, contact_email: "desk@#{name.parameterize}.test")
  end

  def license_for(article, partner, territory: 'US', starts_on: Date.current, ends_on: Date.current + 30, exclusive: false, fee_cents: 10_000)
    Syndication::License.create!(partner: partner, article: article, granted_by: @editor, territory: territory,
      starts_on: starts_on, ends_on: ends_on, exclusive: exclusive, fee_cents: fee_cents)
  end
end
