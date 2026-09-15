# Query object with an explicit clock for reproducible report answers.
class EditorialReport
  def initialize(organization, at: Time.current)
    @organization, @at = organization, at
  end
  def review_backlog
    Article.joins(:publication).where(publications: { organization_id: @organization.id }, state: 'in_review')
  end
  def overdue_cents
    Billing::LineItem.joins(invoice: :subscriber).where(subscribers: { organization_id: @organization.id }, billing_invoices: { settled_at: nil }).where('billing_invoices.due_at < ?', @at).sum(:amount_cents)
  end
  def newsletter_outcomes
    Newsletter::Delivery.joins(campaign: :publication).where(publications: { organization_id: @organization.id }).group(:state).count
  end
end
