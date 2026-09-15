# All transports share these transition and authorization rules.
class EditorialWorkflow
  class InvalidTransition < StandardError; end
  def initialize(author:)
    @author = author
  end

  def save_draft(article, attributes)
    authorize!(article, :update?)
    Article.transaction do
      article.lock! if article.persisted?
      raise InvalidTransition, 'Published articles must remain immutable in this demo' if article.state == 'published'
      article.assign_attributes(attributes.slice(:title, :body))
      article.state = 'draft'
      article.scheduled_at = nil
      article.save!
      article.revisions.create!(author: @author, number: (article.revisions.maximum(:number) || 0) + 1, title: article.title, body: article.body)
      article
    end
  end

  def submit(article, reviewer:)
    authorize!(article, :update?)
    article.with_lock do
      raise InvalidTransition, 'Save a draft before submitting' unless %w[draft changes_requested].include?(article.state) && article.latest_revision
      article.latest_revision.review_assignments.create!(reviewer: reviewer)
      article.update!(state: 'in_review')
    end
  end

  def decide(assignment, outcome:, notes: nil)
    article = assignment.article_revision.article
    authorize!(article, :review?)
    raise Pundit::NotAuthorizedError, 'Only the assigned reviewer can decide' unless assignment.reviewer_id == @author.id
    article.with_lock do
      unless article.state == 'in_review' && article.latest_revision.id == assignment.article_revision_id
        raise InvalidTransition, 'This review is stale; review the latest submitted revision'
      end
      assignment.create_review_decision!(outcome: outcome, notes: notes)
      article.update!(state: outcome)
    end
  end

  def schedule(article, at:)
    authorize!(article, :publish?)
    article.with_lock do
      raise InvalidTransition, 'Approve the latest revision first' unless article.state == 'approved'
      raise InvalidTransition, 'Choose a future time' unless at && at > Time.current
      article.update!(state: 'scheduled', scheduled_at: at)
    end
  end

  def authorize!(article, action)
    raise Pundit::NotAuthorizedError, 'Not permitted in this publication' unless ArticlePolicy.new(@author, article).public_send(action)
  end
end
