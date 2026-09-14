module CanopyContext
  def setup_canopy
    @organization = Organization.create!(name: 'Spec Press', slug: "spec-#{SecureRandom.hex(4)}")
    @publication = @organization.publications.create!(name: 'Spec Notes', slug: "notes-#{SecureRandom.hex(4)}")
    @editor = Author.create!(name: 'Editor', email: "editor-#{SecureRandom.hex(4)}@example.test")
    @writer = Author.create!(name: 'Writer', email: "writer-#{SecureRandom.hex(4)}@example.test")
    @editor.memberships.create!(organization: @organization, role: 'editor')
    @writer.memberships.create!(organization: @organization, role: 'author')
    @workflow = EditorialWorkflow.new(author: @writer)
    @review = EditorialWorkflow.new(author: @editor)
    @article = Article.new(author: @writer, publication: @publication)
    @workflow.save_draft(@article, title: "Story #{SecureRandom.hex(4)}", body: 'An accessible trail beside the river.')
    @subscriber = @organization.subscribers.create!(name: 'Reader', email: 'reader@example.test')
    @plan = @publication.plans.create!(name: 'Monthly', amount_cents: 1200)
    @billing = Billing::SubscriptionWorkflow.new(author: @editor)
  end
  def approve_article
    @workflow.submit(@article, reviewer: @editor)
    @review.decide(@article.latest_revision.review_assignments.first!, outcome: 'approved')
  end
  def publish_article
    approve_article
    PublishArticle.new(author: @editor).call(@article)
  end
  def invoice
    @invoice ||= @billing.activate(subscriber: @subscriber, plan: @plan).invoices.first!
  end
  def login(author = @editor)
    post demo_session_path, params: { author_id: author.id }
  end
end
