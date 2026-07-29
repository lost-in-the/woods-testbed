# ManagerExtractor#manager_file? recognises a "manager" by delegation shape —
# `< SimpleDelegator`, `< DelegateClass(...)`, or `include Delegator`. A plain
# service-shaped class in app/managers produces no unit, which is a surprising
# definition of the word and exactly the kind of thing a fixture should pin.
class SubscriptionManager < SimpleDelegator
  def initialize(author)
    super
    @author = author
  end

  def active?
    @author.invoices.outstanding.none?
  end

  def renew!
    Billing::IssueInvoice.new(author: @author).call(description: "Renewal", amount_cents: 9_900)
  end
end
